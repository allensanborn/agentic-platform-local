#!/usr/bin/env bash
# Agent implementation: Anthropic's Claude Code CLI, headless.
#
# This is the workshop's own agent, invoked the workshop's own way. The only
# thing that differs is where ANTHROPIC_BASE_URL points: the workshop sends it to
# the Envoy AI Gateway's Anthropic route backed by Bedrock; here it goes to the
# same gateway's Anthropic route backed by Ollama on the host. Claude Code is not
# patched, wrapped, or proxied — the compatibility surface is the wire protocol,
# and Envoy AI Gateway v1.0 does the Anthropic-in/OpenAI-out translation itself.
#
# Contract (identical for every script in /opt/agents/):
#   in:  $HOME/task.md, cwd = the cloned repo on a fresh branch
#   env: MODEL_BASE_URL (…/anthropic), MODEL_MAIN, MODEL_SMALL
#   out: the work COMMITTED on the current branch. Never push. Never open a PR.
set -uo pipefail

export ANTHROPIC_BASE_URL="${MODEL_BASE_URL}"
# There is no Anthropic account behind this. The gateway does not check the
# credential, but the CLI requires one to be present, and setting it is also what
# stops Claude Code from trying to run an interactive OAuth login it could never
# complete from inside an egress-locked sandbox.
export ANTHROPIC_AUTH_TOKEN="not-needed"
export ANTHROPIC_API_KEY="not-needed"
export ANTHROPIC_MODEL="${MODEL_MAIN}"
export ANTHROPIC_SMALL_FAST_MODEL="${MODEL_SMALL}"
# No telemetry, no auto-update check, no ad-hoc fetches. All three would be
# denied by the egress policy anyway; turning them off keeps the run from
# spending its wall-clock on connections that cannot succeed.
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_AUTOUPDATER=1
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1

# Redirect stdin from /dev/null: headless Claude Code treats an open, empty stdin
# as "input pending" and stalls ("no stdin data received"), doing no tool work.
# </dev/null makes it use the -p prompt argument and run to completion.
# stream-json + the renderer turns the session into one short line per event, so
# the mirrored pod log shows the agent working live instead of going dark.
claude -p "$(cat "$HOME/task.md")" --dangerously-skip-permissions \
  --output-format stream-json --verbose </dev/null \
  | python3 /opt/agents/stream_filter.py
exit "${PIPESTATUS[0]}"
