#!/usr/bin/env bash
# Show the state of one issue: its comments (the dispatcher's status updates) and
# any PR the run produced. Read-only.
#
#   ./show.sh 1
set -euo pipefail

NUM="${1:?usage: show.sh ISSUE_NUMBER}"
NS=gitea
OWNER=workshop-user
REPO=sample-app

POD="$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}')"
USER="$(kubectl get secret -n "$NS" gitea-admin -o jsonpath='{.data.participant-username}' | base64 -d)"
PASS="$(kubectl get secret -n "$NS" gitea-admin -o jsonpath='{.data.participant-password}' | base64 -d)"
API="http://gitea-http.${NS}.svc.cluster.local:3000/api/v1"

get() { kubectl exec -n "$NS" "$POD" -- curl -sS -u "${USER}:${PASS}" "${API}${1}"; }

echo "=== issue #${NUM} comments ==="
get "/repos/${OWNER}/${REPO}/issues/${NUM}/comments" | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    print("  [%s] %s" % (c["user"]["login"], c["body"].splitlines()[0][:160]))
'

echo ""
echo "=== open pull requests ==="
get "/repos/${OWNER}/${REPO}/pulls?state=all" | python3 -c '
import json, sys
prs = json.load(sys.stdin)
if not prs:
    print("  (none)")
for p in prs:
    print("  #%s  %-40s %s <- %s  by %s" % (
        p["number"], p["title"][:40], p["state"], p["head"]["ref"], p["user"]["login"]))
'
