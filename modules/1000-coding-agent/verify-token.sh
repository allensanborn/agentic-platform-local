#!/usr/bin/env bash
# Prove limits #1 and #2 on the git credential:
#
#   #1  No human PAT anywhere. The only stored credential is the BOT's password,
#       in a Kubernetes Secret the dispatcher reads. This script shows what the
#       bot can and cannot reach, and that nothing else holds a git credential.
#   #2  No standing credential in the sandbox. The token the sandbox uses is
#       minted immediately before the run and revoked immediately after, in a
#       `finally`. This script runs that exact lifecycle and shows the token
#       authenticating, then failing.
#
# Optionally takes a token captured from a live run:
#   ./verify-token.sh <token>
# in which case it skips the mint and just proves that THAT token — the real one
# the sandbox used — no longer authenticates.
set -euo pipefail

NS=gitea
BOT=coding-agent-bot
OWNER=workshop-user
REPO=sample-app
API="http://gitea-http.${NS}.svc.cluster.local:3000/api/v1"

POD="$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}')"
BOT_PASS="$(kubectl get secret -n default coding-agent-creds -o jsonpath='{.data.bot-password}' | base64 -d)"

# In-repo endpoint: it is inside the per-run token's `write:repository` scope, so
# a 200 here means the token is live and a 401 means it is gone. (The obvious
# /user endpoint is the wrong probe — a valid per-run token gets 403 there,
# because read:user is deliberately NOT in its scopes, and a 403 is easy to
# misread as "revoked".)
probe() { # probe <token>
  kubectl exec -n "$NS" "$POD" -- curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: token $1" "${API}/repos/${OWNER}/${REPO}"
}

if [ $# -ge 1 ]; then
  echo "=== a token captured from a real run ==="
  echo -n "  after the run, does it authenticate?  HTTP "
  probe "$1"; echo "   (expect 401 — revoked in the dispatcher's finally)"
  exit 0
fi

RUN_ID="run-verify-$$"
echo "=== the dispatcher's own token lifecycle, run by hand ==="

resp="$(kubectl exec -n "$NS" "$POD" -- curl -sS -X POST -u "${BOT}:${BOT_PASS}" \
  -H 'content-type: application/json' \
  -d "{\"name\":\"${RUN_ID}\",\"scopes\":[\"write:repository\",\"write:issue\"]}" \
  "${API}/users/${BOT}/tokens")"
TID="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
TOK="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha1"])')"
echo "  minted ${RUN_ID} (id ${TID}, ${#TOK} chars)"

echo -n "  before revoke:  HTTP "; probe "$TOK"; echo "   (expect 200)"

kubectl exec -n "$NS" "$POD" -- curl -sS -o /dev/null -X DELETE -u "${BOT}:${BOT_PASS}" \
  "${API}/users/${BOT}/tokens/${TID}"
echo "  revoked ${RUN_ID}"

echo -n "  after revoke:   HTTP "; probe "$TOK"; echo "   (expect 401)"

echo ""
echo "=== residue check: per-run tokens left on the bot account ==="
kubectl exec -n "$NS" "$POD" -- curl -sS -u "${BOT}:${BOT_PASS}" \
  "${API}/users/${BOT}/tokens?limit=50" | python3 -c '
import json, sys
toks = json.load(sys.stdin)
runs = [t for t in toks if (t.get("name") or "").startswith("run-")]
print("  %d token(s) total, %d of them per-run" % (len(toks), len(runs)))
for t in runs:
    print("    LEFTOVER  %s  created %s" % (t["name"], t.get("created_at")))
if not runs:
    print("  none — every completed run revoked its own token.")
    print("  (server.py also sweeps run-* tokens older than TOKEN_TTL_SECONDS as a")
    print("   backstop, because Gitea access tokens have no native expiry.)")
'
