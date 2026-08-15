# ADR 0002 — Envoy AI Gateway's extproc is not wired into the Envoy filter chain

**Status:** RESOLVED (2026-08-15)
**Root cause:** Envoy Gateway was installed without AI Gateway's required `extensionManager` config.

## Symptom

Every request through the gateway returned:

```
No matching route found. It is likely because the model specified in your
request is not configured in the Gateway.
```

…while every piece of configuration reported healthy: `AIGatewayRoute`, `AIServiceBackend` and
`Backend` all `Accepted=True`; the generated `HTTPRoute` correct, `Accepted=True`,
`ResolvedRefs=True`, matching exactly `x-ai-eg-model`; the extproc running as a native sidecar
and logging `AI Gateway External Processor is ready`; Ollama answering fine when called
directly. Nothing anywhere reported an error.

## Root cause

**The AI Gateway controller runs as an Envoy Gateway xDS *extension server*.** Envoy Gateway
must be told to call out to it, via an `extensionManager` block in its own Helm values:

```yaml
config:
  envoyGateway:
    extensionManager:
      hooks:
        xdsTranslator:
          translation:
            listener: {includeAll: true}
            route: {includeAll: true}
            cluster: {includeAll: true}
            secret: {includeAll: true}
          post: [Translation, Cluster, Route]
      service:
        fqdn:
          hostname: ai-gateway-controller.envoy-ai-gateway-system.svc.cluster.local
          port: 1063
```

That post-translation hook is what injects the `ext_proc` HTTP filter into the listener.
Without it Envoy Gateway never consults the AI Gateway controller, so the filter is absent,
the model name is never extracted from the request body into `x-ai-eg-model`, the header match
cannot hit, and the request falls through to the `ai-eg-route-not-found-response` filter —
producing an error message that blames the model configuration, which is where the debugging
time went.

The file is published as
[`manifests/envoy-gateway-values.yaml`](https://github.com/envoyproxy/ai-gateway/blob/main/manifests/envoy-gateway-values.yaml)
in the AI Gateway repo. The install docs describe only the two AI Gateway Helm charts and do
not mention installing Envoy Gateway at all, which is how it got missed.

## What actually found it

Applying the **upstream `examples/basic/basic.yaml` verbatim** and watching it fail *identically*.
That one experiment converted the question from "what is wrong with my config?" — which had
already consumed four wrong fixes — into "what is wrong with this cluster?", and the answer
followed in minutes.

Reach for the known-good reference earlier. A local config that fails and a reference config
that fails are the same bug; a local config that fails while the reference passes is a
different and much smaller search.

## A false lead worth keeping

An early diagnostic ran `kubectl exec ... -c envoy -- curl localhost:19000/config_dump` and
grepped for `ext_proc`, getting `0`. That number was meaningless: there is no `curl` in the
Envoy container, so the command emitted **0 bytes** and the grep counted nothing. Several
conclusions were drawn from it before the byte count was checked.

Verify a diagnostic produces output before trusting what it appears to say. The correct test —
tailing the extproc sidecar during a live request and seeing *zero* activity — proved the same
conclusion honestly.

## Second, unrelated blocker found immediately after

With routing fixed, requests failed with `connection refused` reaching Ollama. Two causes:

1. **Ollama binds `127.0.0.1` by default.** It must run as `OLLAMA_HOST=0.0.0.0:11434` to be
   reachable from inside the cluster.
2. **`host.k3d.internal` is wrong on macOS.** k3d injects it into CoreDNS and it looks like the
   obvious choice, but it resolves to the Docker bridge gateway (`192.168.147.1`) — the Linux VM
   Docker Desktop runs, not the Mac where Ollama listens. Verified from a pod:

   | host | result |
   |---|---|
   | `host.docker.internal` | 200 |
   | `host.k3d.internal` | connection refused |

   Expect this to differ on the Windows/WSL2 target; re-verify rather than assuming.

## Outcome

Lab 0 works. `local-fast` → `llama3.2:1b` and `local-smart` → `qwen3:8b`, both resolved by the
gateway's alias table, and the agent drives `lookup_order` end to end through it.
