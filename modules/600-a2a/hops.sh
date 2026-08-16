#!/usr/bin/env bash
# Persona propagation across BOTH hops, without the orchestrator's model in the path.
#
#   this script -> [agentgateway A2A] -> order-agent -> [agentgateway MCP] -> mcp-server
#
# The proof is not the prose the specialist writes. It is the tool list the order-agent
# discovers, which it logs on every request: that list is produced by agentgateway from the
# token, and the token only got there by surviving the A2A hop. If identity died in the middle,
# every persona would see the same list (or none at all).
#
# Expected, per lab 4's policy:
#   sam (support-associate) -> ['lookup_order', 'initiate_return']
#   ana (sales-analyst)     -> ['lookup_order']
#
# Requires `make a2a-forward` in another shell.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="python3 ${HERE}/a2a-probe.py"
Q="${1:-Where is order ORD-1001, and can I return it? It arrived damaged.}"

for u in sam ana; do
  echo "=== $u : A2A message/send -> order-agent ==="
  $PROBE --agent order --user "$u" --text "$Q"
  echo
done

echo "=== what the order-agent saw at the MCP hop (its own log) ==="
echo "    the tool list differs by persona, so the persona crossed both gateways"
kubectl logs deploy/order-agent --tail=200 2>/dev/null | grep '\[a2a-in\]' | tail -4
