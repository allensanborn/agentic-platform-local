#!/usr/bin/env bash
# The authorization matrix at the A2A hop — model-free, so nothing here depends on the local
# model deciding to route correctly.
#
# Requires `make a2a-forward` in another shell (gateway :8081, Keycloak :8085).
#
# What it shows, in order:
#   1. no token          -> 401 on both specialists. The authn gate (module 800) is real.
#   2. sam, ana          -> 200 on BOTH specialists. Any authenticated persona reaches any
#                           agent; there is no per-agent, per-method or per-skill rule to
#                           write. THIS is the finding (ADR 0011), and it is a pass, not a bug
#                           in this script.
#   3. the CRD schema    -> spec.backend has mcp/ai and no a2a, which is WHY 2 looks like that.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="python3 ${HERE}/a2a-probe.py"

status() {  # status <agent> [user]
  local agent="$1" user="${2:-}"
  if [[ -n "$user" ]]; then
    $PROBE --agent "$agent" --card --user "$user" --quiet 2>/dev/null | awk '{print $2}'
  else
    $PROBE --agent "$agent" --card --quiet 2>/dev/null | awk '{print $2}'
  fi
}

echo "=== A2A route gate: agent card through agentgateway ==="
printf '%-22s %-14s %-14s\n' "caller" "/order-agent" "/product-agent"
printf '%-22s %-14s %-14s\n' "no token" "$(status order)" "$(status product)"
for u in sam ana; do
  printf '%-22s %-14s %-14s\n' "$u" "$(status order "$u")" "$(status product "$u")"
done
echo
echo "  401 for no token  = module 800's Require rule is enforcing."
echo "  200 everywhere else = A2A is authn-ONLY. sam cannot call check_inventory at the MCP"
echo "  hop, but he can reach the product-agent, whose search_products tool is in-process and"
echo "  behind no gateway at all."
echo
echo "=== why: the CRD has no place to hang per-A2A-method authz ==="
echo "--- AgentgatewayBackend.spec (a2a IS routable) ---"
kubectl explain agentgatewaybackend.spec 2>&1 | sed -n '/FIELDS/,$p' | grep -E '^ +[a-z]' || true
echo "--- AgentgatewayPolicy.spec.backend (a2a is NOT governable) ---"
kubectl explain agentgatewaypolicy.spec.backend 2>&1 | sed -n '/FIELDS/,$p' | grep -E '^ +[a-z]' || true
echo
echo -n "  a2a under spec.backend: "
if kubectl explain agentgatewaypolicy.spec.backend 2>/dev/null | grep -qE '^\s+a2a\b'; then
  echo "PRESENT — this finding has expired, update ADR 0011"
else
  echo "ABSENT (expected)"
fi
