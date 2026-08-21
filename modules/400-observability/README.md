# Lab 2 — Observability, and a retraction

> **The control point: the collector.** Every workload speaks plain OTLP to it and holds no credential for the tracing backend. One key to rotate, in one place.

The manifests for this lab live in [`platform/observability/`](../../platform/observability/), not in this directory, because tracing is platform infrastructure shared by every workload rather than something the agent module owns. This file is the lab guide; [`platform/observability/langfuse/README.md`](../../platform/observability/langfuse/README.md) is the sizing and tuning detail.

## Why this lab exists

An agent turn is not one request. It is a model call, possibly several, wrapped in an event loop, with tool calls hanging off it and a gateway hop in the middle. When it is slow or wrong, "which part" is the entire question, and no single service's logs can answer it.

The lab's headline property is **cross-service trace nesting**: one chat turn is one trace containing both the agent's spans and the gateway's, joined by W3C `traceparent`.

## What you run

```bash
make observability                                        # collector + Langfuse
kubectl port-forward -n langfuse svc/langfuse-web 3000:3000
# http://localhost:3000  —  admin@anycompany.local / langfuse123
```

Ask the UI one question, then look for a **single trace with 26 observations**:

```
POST /chat                                      [agent, FastAPI]
  invoke_agent Strands Agents
    execute_event_loop_cycle  x2
      chat  x2
    lookup_order
  ingress                                   x2  [Envoy]
  router httproute/default/local/rule/1 egress  x2  [Envoy]
  async …ExternalProcessor.Process egress   x4  [AI Gateway extproc]
```

## What to look at

**There is no tracing code in the agent.** `opentelemetry-instrument` in the Dockerfile `CMD` does all of it. Strands emits proper GenAI semantic-convention spans — `gen_ai.operation.name`, `gen_ai.agent.name`, `gen_ai.user.message`, `gen_ai.choice` — so the trace is richer than a bare HTTP waterfall for free.

**The agent's OTel config is four environment variables in `agent-config`**, pointing at the collector's ClusterIP. The agent holds no Langfuse credential; the collector is the only egress. That is the control point in one sentence.

**The `telemetry.tracing` block on the `EnvoyProxy`** in [`platform/gateway/ai-gateway.yaml`](../../platform/gateway/ai-gateway.yaml) is what makes the gateway a *participant* in the trace instead of an opaque proxy. Without it you get two unrelated traces and no way to attribute latency to the model hop.

## What should surprise you

**Streaming defeats naive auto-instrumentation, and the fix belongs in the collector.**

The first working trace had **543 spans** for one question. The ASGI middleware opens a span per SSE chunk, so roughly 530 of them were `POST /chat http send` carrying nothing, burying the six that mattered.

The fix is a `filter` processor in the collector — `filter/drop_sse_chunk_spans` in [`otel-collector.yaml`](../../platform/observability/otel-collector.yaml) — **not a change in the app**. 543 spans became 9.

That is the workshop's thesis arriving from an unexpected direction. Telemetry shaping is policy, and policy belongs at the control point. One collector rule fixes it for every workload that will ever stream. It is the same argument lab 4 makes about authorization, made about spans instead.

**If you see two traces instead of one**, the gateway is not continuing the agent's `traceparent`. The historical cause here was the collector's Service missing `appProtocol: grpc`, without which Envoy Gateway generates a tracing cluster with no `http2_protocol_options` and speaks gRPC over HTTP/1.1. The symptom set is vicious: `spans_sent` increments, `spans_dropped` stays `0`, the endpoint reports `HEALTHY`, and the collector logs nothing at all, because it never sees a valid gRPC stream. The comment above that line in the manifest is worth reading in full.

## The retraction, which is the actual lesson of this lab

The original decision ([ADR 0004](../../docs/adr/0004-observability-backend-and-gateway-spans.md)) was **Jaeger instead of Langfuse**, on the grounds that self-hosted Langfuse v4 is six containers with official sizing guidance of 4 cores / 16 GiB against a container VM that appeared to have 11.7 GiB.

Both halves of that were wrong, in different ways.

**The 11.7 GiB was a misread.** OrbStack's `memory_mib` is a configurable soft cap over dynamically allocated memory, not a fixed VM ceiling. With the full cluster plus all of Langfuse running, measured host RSS was 1.6–3.7 GiB.

**The 16 GiB is a production sizing recommendation, not a floor.** It describes an expected ingest rate and default cache sizing, not anything structural.

Measured after actually trying: **Langfuse runs here at ~1.6 GiB idle, ~2.0 GiB under load, zero restarts.** All six containers. The gap between the assumed requirement and the measured floor was roughly a **factor of eight**. Jaeger was deleted; Langfuse is the only trace backend.

One root cause covers most of the savings and generalizes well past Langfuse: **ClickHouse, MinIO and Node all size their memory from host RAM, and none of them reads the cgroup limit.** Each saw ~11.7 GiB and helped itself — ClickHouse reserving a 5 GiB mark cache, Node targeting a 1.7 GiB heap — while their container limits sat unread. Every fix is the same fix: state the number absolutely instead of letting the process infer it. ClickHouse settled at **86 MiB idle against a 2 GiB limit**.

Two gotchas worth carrying out of this lab:

- **"OOM" is two distinct failures.** Raising `langfuse-web`'s container limit without raising `--max-old-space-size` leaves it crash-looping anyway: V8 hits its own 768 MB ceiling and dies with `FATAL ERROR: Ineffective mark-compacts near heap limit` while a third of the container limit goes unused. `kubectl` reports the first as `OOMKilled` and the second as plain `Error`. They are a pair.
- **Shrinking ClickHouse's background pool crashes it at startup**, not under load. It asserts `number_of_free_entries_in_pool_to_execute_mutation <= background_pool_size * background_merges_mutations_concurrency_ratio` and exits `BAD_ARGUMENTS` before the server ever listens.

### The compounding error

While Jaeger was the backend, this project declared an open gap ("gateway spans leave Envoy and never land"), wrote a hypothesis for it (a `TracerProvider` race in `strands-agents[otel]`), and carried both in an ADR.

The gap did not exist. It had already been fixed by the unrelated `appProtocol: grpc` change above. The hypothesized race does not exist either. And the measurements that supported the "gap" were stale queries against **a backend that had since been removed from the cluster**.

> **Re-verify a known gap before writing the next theory about it, especially after changing the thing you measure with.**

The substitution here was reversed not because the software changed but because the premise was finally tested — and it was testable *only* because the original decision had been written down with its reasoning exposed. That is an argument for ADRs that no process document can make.

## What the substitution costs

| | Workshop | Here |
|---|---|---|
| Tracing | Langfuse | **the same**, hand-tuned to ~1.6 GiB |

**Preserved:** all six containers, the LLM-specific UI, token cost attribution, prompt management.

**The one real trade:** sustained ingest throughput. 2000 `telemetrygen` traces at 4 workers ingested 819 in 6m40s without dropping data or restarting a pod, but did not keep up in real time. Irrelevant at demo scale — one person asking an agent questions — and the ClickHouse pool and cache settings are where to give memory back if it ever matters.

## Go deeper

- [ADR 0004 — observability backend, and the gateway-span gap](../../docs/adr/0004-observability-backend-and-gateway-spans.md), kept for *how it failed*
- [ADR 0008 — Langfuse fits after all, at 1.6 GiB](../../docs/adr/0008-langfuse-fits-after-all.md), with the measurements
- [`platform/observability/langfuse/README.md`](../../platform/observability/langfuse/README.md) — the tuning detail
- [TALK.md, Part 3](../../docs/TALK.md#part-3--lab-2-telemetry-and-a-retraction)

**Next:** [Lab 3 — tools behind a gateway](../500-mcp/README.md).
