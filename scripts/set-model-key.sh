#!/usr/bin/env bash
# Load a model-provider API key into the cluster as a Kubernetes SECRET.
#
# Deliberately a Secret and not a ConfigMap. The workshop this repo rebuilds ships its LiteLLM
# master key in the shared `agent-config` ConfigMap, which `envFrom` then hands to every pod in
# the namespace — a live credential in an object that is not encrypted at rest, is readable by
# anything with namespace get, and turns up in `kubectl describe` output pasted into tickets.
# It is the one thing the workshop gets wrong that this rebuild should not copy.
#
# The key never passes through a command line (it would land in shell history and `ps`), and
# never through a file this repo tracks (.secrets/ and *.key are gitignored).
#
# Usage — pick either:
#   printf '%s' 'sk-or-v1-...' > .secrets/openrouter.key && ./scripts/set-model-key.sh
#   OPENROUTER_API_KEY=sk-or-v1-... ./scripts/set-model-key.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
KEY_FILE=".secrets/openrouter.key"

if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  key="$OPENROUTER_API_KEY"
  src="environment"
elif [ -s "$KEY_FILE" ]; then
  key="$(tr -d '[:space:]' < "$KEY_FILE")"
  src="$KEY_FILE"
else
  cat >&2 <<'MSG'
No key found. Provide it one of these ways (neither puts it in shell history):

  printf '%s' 'sk-or-v1-...' > .secrets/openrouter.key   # gitignored
  export OPENROUTER_API_KEY=sk-or-v1-...                 # this shell only

Get a free key at https://openrouter.ai/keys — models with a ":free" suffix cost nothing.
MSG
  exit 1
fi

case "$key" in
  sk-or-*) ;;
  *) echo >&2 "warning: key does not start with 'sk-or-' — is this an OpenRouter key?" ;;
esac

kubectl create namespace model-access --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create secret generic openrouter \
  --namespace model-access \
  --from-literal=api-key="$key" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "secret model-access/openrouter updated from ${src} (${#key} chars)"
echo "the key is NOT written to any tracked file, and not echoed anywhere"
