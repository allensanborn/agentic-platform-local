#!/usr/bin/env bash
# Install gVisor (runsc) into the k3d agent node and register it with containerd.
#
# Why a script and not a manifest: k3d nodes are containers, so the runtime binaries do not
# survive `k3d cluster delete`. Re-run this after any cluster recreate (make up does).
#
# Why gVisor and not Kata + Firecracker: Firecracker needs /dev/kvm, and this node does not
# have it — verified, not assumed:
#     docker exec k3d-agentic-agent-0 ls /dev/kvm   ->  No such file or directory
# See ADR 0005 for what that costs.
set -euo pipefail

NODE="${NODE:-k3d-agentic-agent-0}"
# gVisor publishes under `aarch64`, NOT `arm64` — the arm64 path 404s.
ARCH="$(uname -m)"; [ "$ARCH" = "arm64" ] && ARCH=aarch64
BASE="https://storage.googleapis.com/gvisor/releases/release/latest/${ARCH}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading runsc + shim for ${ARCH}..."
curl -fsSL -o "$tmp/runsc" "${BASE}/runsc"
curl -fsSL -o "$tmp/containerd-shim-runsc-v1" "${BASE}/containerd-shim-runsc-v1"
chmod +x "$tmp/runsc" "$tmp/containerd-shim-runsc-v1"

# /bin, not /usr/local/bin — the k3d node image has no /usr/local.
docker cp "$tmp/runsc" "${NODE}:/bin/runsc"
docker cp "$tmp/containerd-shim-runsc-v1" "${NODE}:/bin/containerd-shim-runsc-v1"
docker exec "$NODE" chmod +x /bin/runsc /bin/containerd-shim-runsc-v1

# k3s imports drop-ins from config-v3.toml.d, so the generated config.toml stays untouched.
docker exec "$NODE" sh -c '
mkdir -p /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d
cat > /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/gvisor.toml <<TOML
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
TOML'

echo "restarting ${NODE} to reload containerd..."
docker restart "$NODE" >/dev/null
until kubectl get node "$NODE" --no-headers 2>/dev/null | grep -q ' Ready '; do sleep 3; done

kubectl apply -f platform/sandbox/runtimeclass-gvisor.yaml
echo "gVisor installed. Verify with: make sandbox-verify"
