#!/usr/bin/env bash
# Unattended runner for the deterministic infra suite (tests/, tier 1 of ADR 0012).
#
# Decision and reasoning: docs/adr/0013-where-the-tests-run.md.
#
# This script is what the LaunchAgent calls. It is also safe to run by hand — it is the
# same code path, so "it works when I run it" means something.
#
# It runs against ITS OWN CLONE, outside ~/Documents, for two reasons documented in
# ADR 0013:
#   1. macOS TCC denies launchd-spawned processes access to ~/Documents. Executing from
#      the everyday checkout dies with "Operation not permitted" (exit 126) before a
#      single log line is written.
#   2. The everyday checkout nearly always has WIP in it. A suite that imports test
#      modules from a tree someone is mid-edit in produces failures attributable to
#      nothing. A clone pinned to origin/main gives every result a commit SHA.
#
# Four outcomes, and collapsing any two of them is the mistake this exists to avoid:
#   PASS  the suite ran, everything passed          exit 0
#   FAIL  the suite ran, something failed           exit 1   <- the real signal
#   HOLD  refused to run; NOTHING was measured      exit 2
#   SKIP  environment legitimately absent           exit 0
set -euo pipefail

REPO_URL="${AGENTIC_TESTS_REPO_URL:-git@github.com:allensanborn/agentic-platform-local.git}"
WORKDIR="${AGENTIC_TESTS_WORKDIR:-$HOME/Library/Application Support/agentic-platform-tests}"
CLONE="$WORKDIR/agentic-platform-local"
LOGDIR="${AGENTIC_TESTS_LOGDIR:-$HOME/Library/Logs/agentic-platform-tests}"
BRANCH="${AGENTIC_TESTS_BRANCH:-main}"
# The make target to run. Parameterised so tier 2 (promptfoo, beads llm-wiki-1fi.3/1fi.4)
# can be scheduled on its own cadence later without rewriting this script.
TEST_TARGET="${AGENTIC_TESTS_TARGET:-test}"
# Set to 0 to make the runner report a degraded gateway as HOLD without touching it.
RECOVER_GATEWAY="${AGENTIC_TESTS_RECOVER_GATEWAY:-1}"
NOTIFY="${AGENTIC_TESTS_NOTIFY:-1}"
CLUSTER_NAME="${CLUSTER:-agentic}"
OLLAMA_URL="${AGENTIC_TESTS_OLLAMA_URL:-http://localhost:11434}"
REQUIRED_MODELS="${AGENTIC_TESTS_MODELS:-qwen3:8b llama3.2:1b}"

TS="$(date +%Y-%m-%dT%H-%M-%S)"
mkdir -p "$LOGDIR" "$WORKDIR"
LOG="$LOGDIR/run-$TS.log"
STATUS_FILE="$LOGDIR/status"

# Everything below goes to both the log and stdout, so a hand-run looks like the real thing.
exec > >(tee -a "$LOG") 2>&1

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }

notify() {
  # Best-effort only. A missing notification must never change the exit code.
  [ "$NOTIFY" = "1" ] || return 0
  command -v osascript >/dev/null 2>&1 || return 0
  local title="$1" msg="$2"
  osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" \
    >/dev/null 2>&1 || true
}

# $1 = PASS|FAIL|HOLD|SKIP, $2 = one-line reason, $3 = exit code
finish() {
  local status="$1" reason="$2" code="$3"
  printf '%s  %s  %s  %s\n' "$status" "$TS" "${SHA:-unknown}" "$reason" > "$STATUS_FILE"
  ln -sfn "$LOG" "$LOGDIR/latest.log"
  log "=== $status: $reason"
  log "log:    $LOG"
  log "status: $STATUS_FILE"
  case "$status" in
    FAIL) notify "Infra suite FAILED" "$reason" ;;
    HOLD) notify "Infra suite HOLD (nothing measured)" "$reason" ;;
  esac
  exit "$code"
}

log "=== agentic-platform infra suite, scheduled run $TS"
log "clone:  $CLONE"
log "target: make $TEST_TARGET"

# ---------------------------------------------------------------- tooling
# A missing tool here is a broken install (almost always the plist's PATH not covering
# Homebrew or ~/.local/bin), not "the demo isn't running today" — so it is a HOLD, which
# notifies. A silent SKIP would let a misinstalled agent look like an idle laptop forever.
for t in git make kubectl docker uv curl; do
  command -v "$t" >/dev/null 2>&1 || finish HOLD "$t not on PATH ($PATH)" 2
done

# ---------------------------------------------------------------- the clone
if [ ! -d "$CLONE/.git" ]; then
  log "cloning $REPO_URL (first run)"
  git clone --quiet "$REPO_URL" "$CLONE" || finish HOLD "clone of $REPO_URL failed" 2
fi

cd "$CLONE"

# Refuse on a dirty tree. This clone is machine-owned and should never be dirty; if it is,
# someone hand-edited it and the result would not be attributable to a commit.
if [ -n "$(git status --porcelain)" ]; then
  git status --short
  finish HOLD "runner clone $CLONE is dirty — refusing to run (nothing was measured)" 2
fi

log "fetching origin/$BRANCH"
git fetch --quiet origin "$BRANCH" || finish HOLD "git fetch failed (network? ssh key?)" 2
git checkout --quiet -B "$BRANCH" "origin/$BRANCH" || finish HOLD "checkout of origin/$BRANCH failed" 2
git reset --quiet --hard "origin/$BRANCH"
SHA="$(git rev-parse --short HEAD)"
log "pinned at $SHA ($(git log -1 --format=%s))"

# ---------------------------------------------------------------- pre-flight
# Docker first: k3d is k3s in Docker, and a hung Docker engine has twice been misread as a
# Kubernetes fault in this project (see beads llm-wiki-661.23).
if ! timeout 30 docker info >/dev/null 2>&1; then
  finish SKIP "Docker is not answering — cluster cannot be up" 0
fi

if ! timeout 30 kubectl cluster-info >/dev/null 2>&1; then
  finish SKIP "no reachable Kubernetes API (cluster '$CLUSTER_NAME' down?)" 0
fi

# Ollama and both models. test_10 asserts two aliases reach DIFFERENT backend models, so a
# missing model is a guaranteed red that says nothing about the platform.
if ! curl -fsS --max-time 10 "$OLLAMA_URL/api/tags" -o "$WORKDIR/.tags.json" 2>/dev/null; then
  finish SKIP "Ollama not answering at $OLLAMA_URL (make serve-model)" 0
fi
for m in $REQUIRED_MODELS; do
  grep -q "\"$m\"" "$WORKDIR/.tags.json" \
    || finish SKIP "Ollama is missing model $m (make model)" 0
done
log "ollama ok; models present: $REQUIRED_MODELS"

# ---------------------------------------------------------------- gateway recovery
# After a capacity collapse the AI gateway does NOT self-heal: controllers come back
# Running and both nodes go Ready while the Gateway sits Programmed=False with no
# data-plane config. That window produced six false product failures once already.
#
# This lives here and NOT in conftest.py on purpose: the suite must never repair what it
# measures. The runner brings the environment to a defined state and says loudly that it
# intervened, so a pass that needed a restart is never read as a cluster that was healthy.
gateway_programmed() {
  local s
  s="$(timeout 30 kubectl get gateway envoy-ai-gateway \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  [ "$s" = "True" ]
}

if ! gateway_programmed; then
  if [ "$RECOVER_GATEWAY" != "1" ]; then
    finish HOLD "Gateway envoy-ai-gateway is not Programmed and recovery is disabled" 2
  fi
  log "RECOVERY: Gateway envoy-ai-gateway is not Programmed — restarting the controllers"
  log "RECOVERY: this run's result is NOT evidence the cluster was healthy unattended"
  timeout 60 kubectl rollout restart deploy/ai-gateway-controller -n envoy-ai-gateway-system || true
  timeout 60 kubectl rollout restart deploy/envoy-gateway -n envoy-gateway-system || true
  timeout 300 kubectl rollout status deploy/ai-gateway-controller -n envoy-ai-gateway-system || true
  timeout 300 kubectl rollout status deploy/envoy-gateway -n envoy-gateway-system || true

  # Give the data plane time to be programmed. One recovery attempt only — never escalate
  # to anything more destructive, because the failure mode here is LOAD.
  for _ in $(seq 1 30); do
    gateway_programmed && break
    sleep 10
  done
  if ! gateway_programmed; then
    finish HOLD "Gateway still not Programmed after one restart — nothing was measured" 2
  fi
  log "RECOVERY: Gateway is Programmed again"
fi

# ---------------------------------------------------------------- run
if [ ! -d "$CLONE/tests/.venv" ]; then
  log "creating the test virtualenv (make test-venv)"
  make -C "$CLONE" test-venv || finish HOLD "make test-venv failed" 2
fi

log "running make $TEST_TARGET"
set +e
make -C "$CLONE" "$TEST_TARGET"
rc=$?
set -e

# pytest.exit(returncode=2) is what the capacity gate uses, so exit 2 means the gate
# refused mid-flight: the cluster degraded between pre-flight and the run. Not a failure.
case "$rc" in
  0) finish PASS "make $TEST_TARGET passed at $SHA" 0 ;;
  2) finish HOLD "CAPACITY HOLD from the suite's own gate — see $LOG and beads llm-wiki-661.23" 2 ;;
  *) finish FAIL "make $TEST_TARGET exited $rc at $SHA — see $LOG" 1 ;;
esac
