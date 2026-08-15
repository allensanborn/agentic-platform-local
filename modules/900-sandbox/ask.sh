#!/usr/bin/env bash
# Ask the in-cluster agent a question AS a Keycloak persona, and print the SSE stream.
#
# The chat UI does this same thing; this is the scriptable version, so a lab-5 claim can be
# reproduced without clicking. Requires port-forwards:
#     kubectl port-forward svc/customer-agent 8082:8080
#     kubectl port-forward -n identity svc/keycloak 8085:8080
#
# Usage: ./ask.sh <user> "<question>"
set -euo pipefail

USER_NAME="${1:?usage: ask.sh <sam|ana> \"<question>\"}"
QUESTION="${2:?usage: ask.sh <sam|ana> \"<question>\"}"

TOKEN="$(curl -sS -X POST \
  "http://127.0.0.1:8085/realms/anycompany/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=anycompany-agent \
  -d "username=${USER_NAME}" -d "password=${USER_NAME}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')"

# A fresh session_id every run: tool discovery happens on the FIRST message of a session,
# so reusing one would show a cached tool list after a policy change.
curl -sS -N -X POST http://127.0.0.1:8082/chat \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c '
import json, sys, uuid
print(json.dumps({
    "query": sys.argv[1],
    "session_id": f"cli-{uuid.uuid4()}",
    "actor_id": sys.argv[2],
    "access_token": sys.argv[3],
}))' "$QUESTION" "$USER_NAME" "$TOKEN")"
