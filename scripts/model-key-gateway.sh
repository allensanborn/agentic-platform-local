#!/usr/bin/env bash
# Derive the gateway-shaped API-key Secret from the human-shaped one.
#
# ./scripts/set-model-key.sh writes Secret `openrouter` in namespace
# `model-access` with the key under `api-key`. Envoy AI Gateway's
# BackendSecurityPolicy requires a Secret in the AIServiceBackend's own namespace
# whose key is literally `apiKey`. Rather than ask a human to type a credential
# twice — the reliable way to end up with two credentials, one of them stale —
# this copies it across.
#
# The key still never appears on a command line: it is read into a variable and
# handed to `kubectl create secret --from-file=/dev/stdin` equivalent via a
# here-doc-free `--from-literal` in a subshell would leak it to `ps`, so the
# manifest is generated and piped instead.
set -euo pipefail

SRC_NS=model-access
SRC_NAME=openrouter
SRC_KEY=api-key
DST_NS=default
DST_NAME=openrouter-apikey
DST_KEY=apiKey

b64="$(kubectl get secret -n "$SRC_NS" "$SRC_NAME" -o "jsonpath={.data.$SRC_KEY}" 2>/dev/null || true)"
if [ -z "$b64" ]; then
  echo "No key in ${SRC_NS}/${SRC_NAME}. Run ./scripts/set-model-key.sh first." >&2
  exit 1
fi

# Pass the value through as base64 the whole way, so the plaintext key never
# exists as an argv entry.
kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: ${DST_NAME}
  namespace: ${DST_NS}
type: Opaque
data:
  ${DST_KEY}: ${b64}
EOF

echo "secret ${DST_NS}/${DST_NAME} (key '${DST_KEY}') is in sync with ${SRC_NS}/${SRC_NAME}"
