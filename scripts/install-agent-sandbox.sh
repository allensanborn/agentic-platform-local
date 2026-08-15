#!/usr/bin/env bash
# Install the upstream kubernetes-sigs/agent-sandbox control plane (v0.5.0) into the
# k3d cluster, then the local gVisor SandboxTemplate + WarmPool.
#
# This is the lab-5 platform. It is the SAME install the workshop's Terraform
# (agentsandbox.tf) performs, with exactly two substitutions:
#   * images come from the upstream registries directly, not an ECR mirror
#     (both registry.k8s.io/agent-sandbox/agent-sandbox-controller:v0.5.0 and
#      us-central1-docker.pkg.dev/.../sandbox-router:latest-main publish arm64 —
#      verified with `docker manifest inspect`, so nothing had to be rebuilt);
#   * the SandboxTemplate says runtimeClassName: gvisor, not kata-fc (ADR 0005).
#
# Re-runnable: every step is `kubectl apply`.
set -euo pipefail

cd "$(dirname "$0")/.."
MANIFESTS=platform/sandbox/agent-sandbox

# 1. Controller + core CRDs (Sandbox).
kubectl apply --server-side -f "$MANIFESTS/manifest.yaml"
# 2. Extensions: SandboxTemplate / SandboxWarmPool / SandboxClaim CRDs + controller.
kubectl apply --server-side -f "$MANIFESTS/extensions.yaml"

# 3. CRDs Established before any CR is applied.
kubectl wait --for=condition=Established --timeout=120s \
  crd/sandboxes.agents.x-k8s.io \
  crd/sandboxtemplates.extensions.agents.x-k8s.io \
  crd/sandboxwarmpools.extensions.agents.x-k8s.io \
  crd/sandboxclaims.extensions.agents.x-k8s.io

# 4. Controller Available (it also serves a validating webhook; CRs are rejected
#    until the webhook cert secret is minted and the endpoint is live).
kubectl wait --for=condition=Available --timeout=300s \
  -n agent-sandbox-system deploy --all

# 5. Sandbox namespace. The NetworkPolicy namespaceSelector matches on
#    kubernetes.io/metadata.name, so make sure the label is present.
kubectl create namespace agent-sandbox --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace agent-sandbox kubernetes.io/metadata.name=agent-sandbox --overwrite

# 6. Router + its ingress lock. replicas is patched to 1 and the zone
#    topologySpreadConstraint is harmless on a 2-node k3d cluster.
sed 's|\${ROUTER_IMAGE}|us-central1-docker.pkg.dev/k8s-staging-images/agent-sandbox/sandbox-router:latest-main|' \
  "$MANIFESTS/sandbox_router.yaml" | kubectl apply -n agent-sandbox-system -f -
kubectl apply -f platform/sandbox/router-ingress-networkpolicy.yaml
kubectl wait --for=condition=Available --timeout=300s \
  -n agent-sandbox-system deploy/sandbox-router-deployment

# 7. gVisor SandboxTemplate + WarmPool + the supplemental air-gap policy.
kubectl apply -f platform/sandbox/sandboxtemplate-gvisor-python.yaml
kubectl apply -f platform/sandbox/sandboxwarmpool-gvisor-python.yaml
kubectl apply -f platform/sandbox/sandbox-airgap-networkpolicy.yaml

echo "agent-sandbox installed. Verify with: make sandbox-pool"
