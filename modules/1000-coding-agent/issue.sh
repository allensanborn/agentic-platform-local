#!/usr/bin/env bash
# File an issue on the seed repo and put the trigger label on it — i.e. do the
# one thing a human does in labs 6-7. Everything after this is the platform.
#
#   ./issue.sh "Add a /health endpoint" "Return {\"status\": \"ok\"}."
#
# The label is applied as a SEPARATE call, on purpose: the dispatcher triggers on
# label-change actions only, so creating an issue that already carries the label
# would fire both `opened` and a label event and the run would happen twice. This
# is the workshop's own trigger rule (webhook.TRIGGER_ACTIONS), exercised the way
# it expects.
#
# Note whose credential this is: the HUMAN's Gitea password, used by the human,
# from the human's laptop, to file an issue. It is never handed to the agent, the
# sandbox, or the dispatcher. The agent's credential is a different thing that
# does not exist yet at this point in the story.
set -euo pipefail

TITLE="${1:?usage: issue.sh TITLE [BODY]}"
BODY="${2:-}"
NS=gitea
OWNER=workshop-user
REPO=sample-app
LABEL=agent

POD="$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}')"
USER="$(kubectl get secret -n "$NS" gitea-admin -o jsonpath='{.data.participant-username}' | base64 -d)"
PASS="$(kubectl get secret -n "$NS" gitea-admin -o jsonpath='{.data.participant-password}' | base64 -d)"
API="http://gitea-http.${NS}.svc.cluster.local:3000/api/v1"

api() { # api METHOD PATH [json]
  kubectl exec -n "$NS" "$POD" -- curl -sS -X "$1" -u "${USER}:${PASS}" \
    -H 'content-type: application/json' ${3:+-d "$3"} "${API}${2}"
}

payload="$(python3 -c 'import json,sys; print(json.dumps({"title": sys.argv[1], "body": sys.argv[2]}))' "$TITLE" "$BODY")"
NUM="$(api POST "/repos/${OWNER}/${REPO}/issues" "$payload" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')"
echo "filed issue #${NUM}: ${TITLE}"

# The label id, then the label. This is the webhook trigger.
LID="$(api GET "/repos/${OWNER}/${REPO}/labels" \
        | python3 -c "import json,sys; print([l['id'] for l in json.load(sys.stdin) if l['name']=='${LABEL}'][0])")"
api POST "/repos/${OWNER}/${REPO}/issues/${NUM}/labels" "{\"labels\":[${LID}]}" >/dev/null
echo "labelled '${LABEL}' -> webhook fired"
echo ""
echo "watch:  kubectl logs -f deploy/coding-agent-dispatcher"
echo "        kubectl logs -f -n agent-sandbox -l sandbox-kind=coding"
echo "read:   make coding-issue-show N=${NUM}"
