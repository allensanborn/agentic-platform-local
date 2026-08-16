#!/usr/bin/env bash
# Ask the ORCHESTRATOR a question as a Keycloak persona and print the SSE stream — the full
# three-hop path, model and all.
#
#   you -> orchestrator -> [agentgateway A2A] -> specialist -> [agentgateway MCP] -> mcp-server
#
# Sibling of modules/900-sandbox/ask.sh, same shape. Requires `make a2a-forward`:
#     orchestrator :8083   Keycloak :8085
#
# Usage: ./ask.sh <sam|ana> "<question>"
#
# Caveat worth stating before you run it: the routing decision here belongs to the local model,
# and qwen3:8b is a weak router. If it answers from its own knowledge instead of delegating,
# that is the MODEL failing, not the hop — use hops.sh, which removes the model, to tell the
# two apart. Setting MODEL_ID=remote-smart on the a2a-config ConfigMap routes the orchestrator
# to the hosted model instead.
set -euo pipefail

USER_NAME="${1:?usage: ask.sh <sam|ana> \"<question>\"}"
QUESTION="${2:?usage: ask.sh <sam|ana> \"<question>\"}"

TOKEN="$(curl -sS -X POST \
  "http://127.0.0.1:8085/realms/anycompany/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=anycompany-agent \
  -d "username=${USER_NAME}" -d "password=${USER_NAME}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')"

# A fresh session_id every run: the orchestrator caches an agent per session for trace
# labelling, and reusing an id across personas would mislabel the trace.
curl -sS -N -X POST http://127.0.0.1:8083/chat \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${TOKEN}" \
  -d "$(python3 -c '
import json, sys, uuid
print(json.dumps({
    "query": sys.argv[1],
    "session_id": f"cli-{uuid.uuid4()}",
    "actor_id": sys.argv[2],
    "access_token": sys.argv[3],
}))' "$QUESTION" "$USER_NAME" "$TOKEN")"
