#!/usr/bin/env bash
# Provision Gitea for labs 6-7. Idempotent (safe to re-run).
#
# Local port of the workshop's terraform/scripts/gitea-provision.sh. Same steps,
# same order, same API calls. The one structural difference: the workshop gets
# its passwords from Terraform `random_password` resources, and Terraform is the
# thing that remembers them. There is no Terraform here, so this script is its
# own state store — it generates each secret ONCE and keeps it in two Kubernetes
# Secrets, then reads them back on every later run. That is what makes the
# script re-runnable without locking the bot out of its own account.
#
# NOTHING here ever writes a credential to the repo working tree.
set -euo pipefail

NS=gitea
ADMIN_USER=workshop-admin
BOT_USER=coding-agent-bot
PARTICIPANT_USER=workshop-user
SEED_REPO=sample-app
TRIGGER_LABEL=agent
DISPATCHER_WEBHOOK_URL=http://coding-agent-dispatcher.default.svc.cluster.local:8080/webhook
SEED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/seed/sample-app"

kubectl -n "$NS" rollout status deployment/gitea --timeout=300s

POD="$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=gitea \
        -o jsonpath='{.items[0].metadata.name}')"
API="http://gitea-http.${NS}.svc.cluster.local:3000/api/v1"

# --- secrets: generate once, then read back -----------------------------------
# Random alphanumeric of length $1. Written so no stage of the pipeline is
# killed by SIGPIPE: the obvious `tr -dc … </dev/urandom | head -c N` makes head
# exit first, tr dies with 141, and `set -o pipefail` turns that into a silent
# whole-script abort at the FIRST password generated. (Diagnosed the hard way —
# the script exited 141 having printed only the rollout line.) Here `head` bounds
# the read up front and `cut` consumes all of its input, so every stage exits 0.
gen() {
  head -c "$(( ${1:-24} * 4 ))" /dev/urandom | base64 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}"
}

# read_secret <ns> <name> <key> -> the decoded value, or empty if absent.
# The trailing `|| true` is load-bearing under `set -e`: with no such secret the
# jsonpath is empty, base64 exits non-zero, and the enclosing
# `VAR="$(read_secret …)"` assignment would take the whole script down on the
# very first (bootstrap) run.
read_secret() {
  kubectl get secret -n "$1" "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true
}

ADMIN_PASS="$(read_secret "$NS" gitea-admin password)";        ADMIN_PASS="${ADMIN_PASS:-$(gen 24)}"
BOT_PASS="$(read_secret default coding-agent-creds bot-password)"; BOT_PASS="${BOT_PASS:-$(gen 24)}"
PARTICIPANT_PASS="$(read_secret "$NS" gitea-admin participant-password)"; PARTICIPANT_PASS="${PARTICIPANT_PASS:-$(gen 20)}"
WEBHOOK_SECRET="$(read_secret default coding-agent-creds webhook-secret)"; WEBHOOK_SECRET="${WEBHOOK_SECRET:-$(gen 32)}"

kubectl create secret generic gitea-admin -n "$NS" \
  --from-literal=username="$ADMIN_USER" \
  --from-literal=password="$ADMIN_PASS" \
  --from-literal=participant-username="$PARTICIPANT_USER" \
  --from-literal=participant-password="$PARTICIPANT_PASS" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# The one machine credential the platform stores. NOTE what is NOT in it: any
# human's personal access token. The dispatcher signs in as the bot and mints
# its own short-lived tokens; a human never handles a git credential (limit #1).
kubectl create secret generic coding-agent-creds -n default \
  --from-literal=bot-username="$BOT_USER" \
  --from-literal=bot-password="$BOT_PASS" \
  --from-literal=webhook-secret="$WEBHOOK_SECRET" \
  --from-literal=repo-owner="$PARTICIPANT_USER" \
  --from-literal=repo-name="$SEED_REPO" \
  --from-literal=trigger-label="$TRIGGER_LABEL" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

exec_gitea() { kubectl exec -n "$NS" "$POD" -- "$@"; }
api() { # api METHOD PATH [json]
  local method="$1" path="$2" body="${3:-}"
  kubectl exec -n "$NS" "$POD" -- curl -sS -X "$method" \
    -u "${ADMIN_USER}:${ADMIN_PASS}" -H 'content-type: application/json' \
    ${body:+-d "$body"} "${API}${path}"
}

# 1. Admin, bot and participant accounts. `|| true` on "already exists" is what
#    makes a re-run a no-op. --must-change-password=false matters: the default
#    is true, and a must-change account cannot use the API.
echo "== users"
exec_gitea gitea admin user create --admin --username "$ADMIN_USER" \
  --password "$ADMIN_PASS" --email admin@example.com --must-change-password=false || true
exec_gitea gitea admin user create --username "$BOT_USER" \
  --password "$BOT_PASS" --email bot@example.com --must-change-password=false || true
exec_gitea gitea admin user create --username "$PARTICIPANT_USER" \
  --password "$PARTICIPANT_PASS" --email participant@example.com --must-change-password=false || true

# 2. The repo, owned by the participant, created EMPTY and then seeded by push
#    so the history looks like a human wrote the starter app.
echo "== repo"
api POST "/admin/users/${PARTICIPANT_USER}/repos" \
  "{\"name\":\"${SEED_REPO}\",\"auto_init\":false,\"private\":false,\"default_branch\":\"main\"}" \
  >/dev/null || true

# 2b. Seed push. Tolerant of re-runs: with content already present the push is a
#     rejected no-op. Gitea's image is Alpine (sh, not bash).
echo "== seed"
kubectl exec -n "$NS" "$POD" -- rm -rf /tmp/sample-app
kubectl cp "$SEED_DIR" "$NS/$POD:/tmp/sample-app"
kubectl exec -n "$NS" "$POD" -- sh -c "
  set -e
  cd /tmp/sample-app
  git init -q
  git config user.email 'workshop-user@example.com'
  git config user.name 'workshop-user'
  git add -A
  git commit -q -m 'Initial sample app'
  git branch -M main
  git remote add origin 'http://${PARTICIPANT_USER}:${PARTICIPANT_PASS}@gitea-http.${NS}.svc.cluster.local:3000/${PARTICIPANT_USER}/${SEED_REPO}.git'
  git push -u origin main
" >/dev/null 2>&1 || echo "   seed push skipped (repo already has content)"
kubectl exec -n "$NS" "$POD" -- rm -rf /tmp/sample-app || true

# 3. The bot is a write collaborator on THIS repo only. That is the blast radius
#    of a per-run token: token scopes in Gitea are per-category, not per-repo, so
#    the containment comes from what the bot account can reach at all.
echo "== collaborator + label + webhook"
api PUT "/repos/${PARTICIPANT_USER}/${SEED_REPO}/collaborators/${BOT_USER}" \
  '{"permission":"write"}' >/dev/null || true

# 4. The opt-in trigger label.
api POST "/repos/${PARTICIPANT_USER}/${SEED_REPO}/labels" \
  "{\"name\":\"${TRIGGER_LABEL}\",\"color\":\"#0e8a16\"}" >/dev/null || true

# 5. The issues webhook -> dispatcher, HMAC-signed with the shared secret.
#    Re-registering would create a duplicate hook, so check first.
if kubectl exec -n "$NS" "$POD" -- curl -sS -u "${ADMIN_USER}:${ADMIN_PASS}" \
     "${API}/repos/${PARTICIPANT_USER}/${SEED_REPO}/hooks" | grep -q "$DISPATCHER_WEBHOOK_URL"; then
  echo "   webhook already registered"
else
  api POST "/repos/${PARTICIPANT_USER}/${SEED_REPO}/hooks" \
    "{\"type\":\"gitea\",\"active\":true,\"events\":[\"issues\"],\"config\":{\"url\":\"${DISPATCHER_WEBHOOK_URL}\",\"content_type\":\"json\",\"secret\":\"${WEBHOOK_SECRET}\"}}" \
    >/dev/null
fi

echo ""
echo "gitea provisioning complete"
echo "  UI:            make gitea-ui   ->  http://127.0.0.1:3001/"
echo "  human login:   ${PARTICIPANT_USER} / ${PARTICIPANT_PASS}"
echo "  admin login:   ${ADMIN_USER} / ${ADMIN_PASS}"
echo "  repo:          http://127.0.0.1:3001/${PARTICIPANT_USER}/${SEED_REPO}"
