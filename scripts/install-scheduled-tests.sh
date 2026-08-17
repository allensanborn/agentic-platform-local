#!/usr/bin/env bash
# Install (or refresh, or remove) the LaunchAgent that runs the infra suite daily.
#
#   scripts/install-scheduled-tests.sh              install / refresh
#   scripts/install-scheduled-tests.sh --uninstall   remove
#   scripts/install-scheduled-tests.sh --dry-run     show what it would do
#
# Decision and reasoning: docs/adr/0013-where-the-tests-run.md.
#
# This is deliberately NOT a make target. Installing a background daemon that runs a
# 6.5-minute suite against a live cluster is a rare, opt-in act; putting it in the
# Makefile invites it being run by muscle memory alongside `make up-all`.
#
# It COPIES the runner and a path-substituted plist into ~/Library/ rather than pointing
# launchd at the checkout, because macOS TCC denies launchd-spawned processes access to
# ~/Documents — executing from the checkout fails with "Operation not permitted"
# (exit 126) before a single log line is written.
#
# CONSEQUENCE, and it is the footgun the parent repo (llm-wiki) documents: RE-RUN THIS
# AFTER EDITING scripts/run-tests-scheduled.sh OR THE PLIST TEMPLATE. A `git pull` does
# not update the installed copies.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

LABEL="local.agentic-platform.tests"
SRC_RUNNER="$SCRIPT_DIR/run-tests-scheduled.sh"
SRC_PLIST="$SCRIPT_DIR/agentic-platform-tests.plist.template"

INSTALL_DIR="$HOME/Library/Application Support/agentic-platform-tests"
DEST_RUNNER="$INSTALL_DIR/run-tests-scheduled.sh"
PLIST_DIR="$HOME/Library/LaunchAgents"
DEST_PLIST="$PLIST_DIR/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/agentic-platform-tests"

DRY_RUN=0
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)   sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 64 ;;
  esac
done

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf 'would: %s\n' "$*"
  else
    "$@"
  fi
}

[ "$(uname -s)" = "Darwin" ] || { echo "launchd is macOS-only; this is $(uname -s)." >&2; exit 1; }

DOMAIN="gui/$(id -u)"

if [ "$UNINSTALL" = "1" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "would: launchctl bootout $DOMAIN/$LABEL"
    echo "would: rm -f $DEST_PLIST"
    echo "would: rm -rf $INSTALL_DIR   (logs in $LOGDIR are KEPT)"
  else
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$DEST_PLIST"
    rm -rf "$INSTALL_DIR"
    echo "removed $LABEL. Logs kept at $LOGDIR"
  fi
  exit 0
fi

for f in "$SRC_RUNNER" "$SRC_PLIST"; do
  [ -f "$f" ] || { echo "missing source file: $f" >&2; exit 1; }
done
bash -n "$SRC_RUNNER" || { echo "runner failed its syntax check; refusing to install" >&2; exit 1; }

# The PATH baked into the plist. launchd gives the job almost nothing, so this fixed list
# is what the runner will actually see. Everything it needs must be reachable from here,
# and the runner HOLDs loudly (rather than SKIPping quietly) if it is not — a misinstalled
# agent must never look like an idle laptop.
RESOLVED_PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
missing=""
for t in git make kubectl docker uv curl; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
[ -z "$missing" ] || echo "WARNING: not on your interactive PATH either:$missing" >&2

echo "label:   $LABEL"
echo "runner:  $SRC_RUNNER  ->  $DEST_RUNNER"
echo "plist:   $DEST_PLIST"
echo "logs:    $LOGDIR"
echo "repo:    $REPO_ROOT (source only — the job runs against its own clone)"
echo

run mkdir -p "$INSTALL_DIR" "$PLIST_DIR" "$LOGDIR"
run cp "$SRC_RUNNER" "$DEST_RUNNER"
run chmod +x "$DEST_RUNNER"

if [ "$DRY_RUN" = "1" ]; then
  echo "would: render $SRC_PLIST -> $DEST_PLIST"
else
  sed -e "s|__RUNNER__|$DEST_RUNNER|g" \
      -e "s|__LOGDIR__|$LOGDIR|g" \
      -e "s|__HOME__|$HOME|g" \
      -e "s|__PATH__|$RESOLVED_PATH|g" \
      "$SRC_PLIST" > "$DEST_PLIST"
  plutil -lint "$DEST_PLIST" >/dev/null || {
    echo "rendered plist is not valid; leaving it in place for inspection" >&2; exit 1; }
fi

# bootout-then-bootstrap, so this is a refresh as well as an install.
run launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
run launchctl bootstrap "$DOMAIN" "$DEST_PLIST"

if [ "$DRY_RUN" = "1" ]; then
  exit 0
fi

cat <<EOF

Installed. Daily at 09:20 local; if the Mac is asleep, launchd runs it once on next wake.

  run now:    launchctl kickstart -p $DOMAIN/$LABEL
  last result: cat $LOGDIR/status
  full log:    less $LOGDIR/latest.log
  remove:      $SCRIPT_DIR/install-scheduled-tests.sh --uninstall

Re-run this installer after editing run-tests-scheduled.sh or the plist template —
a git pull does not update the copies in ~/Library.
EOF
