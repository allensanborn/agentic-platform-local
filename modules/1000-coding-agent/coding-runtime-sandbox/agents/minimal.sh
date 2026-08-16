#!/usr/bin/env bash
# Agent implementation: the minimal tool-calling agent (agents/minimal.py).
# Same contract as claude.sh — task.md in, a commit on the current branch out,
# and no push credential ever in its hands.
set -uo pipefail
exec python3 /opt/agents/minimal.py
