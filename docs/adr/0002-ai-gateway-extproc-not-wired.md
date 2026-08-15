# ADR 0002 — Envoy AI Gateway's extproc is not wired into the Envoy filter chain

**Status:** open blocker (lab 0)
**Date:** 2026-08-15

## Context

Lab 0 routes model traffic through Envoy AI Gateway so the agent asks for an alias
(`local-fast`) and the gateway rewrites it to a real backend model (`qwen3:8b`) via
`modelNameOverride`. Every request returns:

```
No matching route found. It is likely because the model specified in your
request is not configured in the Gateway.
```

## What was verified as working

- `AIGatewayRoute`, `AIServiceBackend`, `Backend` all reconcile: `Accepted=True`.
- The generated `HTTPRoute` is correct — `Accepted=True`, `ResolvedRefs=True`, and its
  match is exactly `x-ai-eg-model: local-fast` with `backendRef` to the Ollama Backend.
- The extproc **is** present as a native sidecar (init container `ai-gateway-extproc`,
  pod is 3/3) and logs `AI Gateway External Processor is ready`.
- Ollama answers correctly when called directly, so the backend is fine.
- `AIServiceBackend.spec.schema.name` accepts `OpenAI`, which confirms the larger
  question: **Envoy AI Gateway does support arbitrary OpenAI-compatible backends.**
  That M0 spike resolves positively.

## Root cause

The extproc never sees the request. Tailing the sidecar during a live request produces
**zero output**, which means the ext_proc HTTP filter is absent from Envoy's chain. The
model name is therefore never extracted into `x-ai-eg-model`, the header match cannot
hit, and the request falls through to the `ai-eg-route-not-found-response-local`
filter — which is precisely the error observed.

No `EnvoyExtensionPolicy` or `EnvoyPatchPolicy` is created by the controller.

## A false lead worth recording

An earlier diagnostic ran `kubectl exec ... -c envoy -- curl localhost:19000/config_dump`
and grepped for `ext_proc`, getting 0. That number was meaningless — the command returns
**0 bytes**, because there is no `curl` in the Envoy container. Several conclusions were
briefly drawn from it before the byte count was checked. Verify that a diagnostic
produces output before trusting what it appears to say.

## Attempted, did not resolve

1. `enableBackend: true` — required for the `Backend` CRD, but unrelated.
2. `enableEnvoyPatchPolicy: true` — no `EnvoyPatchPolicy` gets created regardless.
3. Upgrading AI Gateway v0.4.0 → **v1.0.0** (the current documented release; also moves
   the API from `v1alpha1` to `v1beta1`, matching the workshop's version). Same result.
4. Creating a `GatewayConfig` (new in v1.0.0, whose `spec.extProc` configures exactly
   this) and referencing it from `GatewayClass.spec.parametersRef` — rejected with
   `unsupported parametersRef`. Reverted.

## Next steps

- Find how a `GatewayConfig` is meant to attach to a Gateway in v1.0.0 — it is the
  strongest candidate, since its entire purpose is extproc configuration.
- Check the Envoy Gateway version pairing. The v1.0.0 install docs do not mention
  installing Envoy Gateway at all, so the separately-installed v1.5.6 here may be an
  untested or wrong combination.
- Compare against the upstream `examples/basic/basic.yaml`, which is known-good.

## Consequence

Lab 1 is unblocked and working — the agent talks to Ollama directly via `MODEL_BASE_URL`.
That env var is the whole seam, so inserting the gateway later is a config change and no
code change, which is itself the property the workshop is demonstrating.
