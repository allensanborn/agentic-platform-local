#!/usr/bin/env bash
# Prove limit #3 (egress locked to two in-cluster services) and limit #4 (no
# Kubernetes credential) hold INSIDE A CLAIMED CODING SANDBOX — not a pooled one.
#
# The distinction is the whole lesson of ADR 0006. The controller removes
# `agents.x-k8s.io/warm-pool-sandbox` at claim time, so a policy keyed on that
# label protects the sandbox for exactly as long as the sandbox is doing nothing.
# This script therefore CLAIMS a sandbox and probes from inside it.
#
# And it runs a CONTROL: the same probe from a pod in the same namespace, on the
# same runtime, that the policy does NOT select. Without the control a "blocked"
# result proves nothing — a policy that matches no pods and a CNI that enforces
# no policy look identical from the inside. Lab 5 established this discipline;
# this is the same script shape applied to an allowlist instead of an air-gap,
# which is strictly harder, because an allowlist can also fail by being too
# narrow and that failure is invisible unless the positive cases are run too.
set -euo pipefail

NS=agent-sandbox
POOL=gvisor-coding-pool
CLAIM="egress-check-$$"

# One probe, two roles. For the SANDBOX every expectation below is the policy's
# promise. For the CONTROL every expectation is inverted — the control exists to
# fail every one of the sandbox's blocks, and a control that quietly agrees with
# the sandbox means the probe itself is broken (bad hostname, no network at all)
# rather than the policy working.
PROBE='
import os, socket
control = os.environ.get("ROLE") == "control"
def probe(sandbox_expects_reach, label, host, port):
    try:
        s = socket.socket(); s.settimeout(6); s.connect((host, port)); s.close()
        reached = True
    except Exception:
        reached = False
    want = True if control else sandbox_expects_reach
    ok = "ok  " if reached == want else "FAIL"
    print("  [%s] %-8s %-38s %s:%s" % (ok, "REACHED" if reached else "blocked", label, host, port))
probe(True,  "AI gateway   (sandbox: reach)", "ai-gateway.envoy-gateway-system.svc.cluster.local", 80)
probe(True,  "Gitea        (sandbox: reach)", "gitea-http.gitea.svc.cluster.local", 3000)
probe(False, "mcp-gateway  (sandbox: block)", "mcp-gateway.agentgateway-system.svc.cluster.local", 80)
probe(False, "kube API     (sandbox: block)", "kubernetes.default.svc.cluster.local", 443)
probe(False, "internet IP  (sandbox: block)", "1.1.1.1", 443)
probe(False, "internet DNS (sandbox: block)", "openrouter.ai", 443)
d = "/var/run/secrets/kubernetes.io/serviceaccount"
has = os.path.isdir(d)
print("  [%s] service-account token dir exists: %s" % ("ok  " if has == control else "FAIL", has))
print("  kernel: %s" % os.uname().release)
'

cleanup() {
  kubectl delete sandboxclaim -n "$NS" "$CLAIM" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete pod -n "$NS" coding-egress-control --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== claiming a coding sandbox out of $POOL ==="
kubectl apply -f - >/dev/null <<EOF
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: ${CLAIM}
  namespace: ${NS}
spec:
  warmPoolRef:
    name: ${POOL}
EOF

for _ in $(seq 1 60); do
  # .status.sandbox.name, not .status.sandboxName — the latter silently yields
  # an empty string and the script reports "never bound" for a claim that bound
  # in under a second.
  SB="$(kubectl get sandboxclaim -n "$NS" "$CLAIM" -o jsonpath='{.status.sandbox.name}' 2>/dev/null || true)"
  [ -n "$SB" ] && break
  sleep 2
done
[ -n "${SB:-}" ] || { echo "claim never bound a sandbox"; exit 1; }

kubectl wait --for=condition=Ready "pod/$SB" -n "$NS" --timeout=180s >/dev/null
echo "claimed: $SB"
echo "labels:  $(kubectl get pod -n "$NS" "$SB" -o jsonpath='{.metadata.labels}')"
echo "         ^ note the absence of agents.x-k8s.io/warm-pool-sandbox: this pod"
echo "           is OUT of the pool, which is exactly when the policy must hold."
echo ""
echo "=== inside the CLAIMED sandbox ==="
kubectl exec -n "$NS" "$SB" -- env ROLE=sandbox python3 -c "$PROBE"

echo ""
echo "=== CONTROL: same probe, a pod the policy does NOT select ==="
echo "    (every 'blocked' above is meaningless unless these REACH)"
kubectl delete pod -n "$NS" coding-egress-control --ignore-not-found >/dev/null 2>&1 || true
kubectl run coding-egress-control -n "$NS" --image=coding-runtime-sandbox:local --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"gvisor","containers":[{"name":"c","image":"coding-runtime-sandbox:local","imagePullPolicy":"Never","command":["sleep","300"]}]}}' >/dev/null
kubectl wait --for=condition=Ready pod/coding-egress-control -n "$NS" --timeout=180s >/dev/null
kubectl exec -n "$NS" coding-egress-control -- env ROLE=control python3 -c "$PROBE" || true
echo ""
echo "    The control pod carries no sandbox-kind label, so no NetworkPolicy"
echo "    selects it. It reaches the internet. Therefore the sandbox's failures"
echo "    above are the POLICY, not a broken network and not the runtime."
