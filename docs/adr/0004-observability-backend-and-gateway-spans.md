# ADR 0004 — Observability: Jaeger instead of Langfuse, and the gateway-span gap

**Status:** superseded in part by ADR 0008 — the Langfuse sizing claim below was wrong
**Date:** 2026-08-15

## Backend: Jaeger, not Langfuse

> **Retracted.** The premise of this section — that Langfuse could not fit on this machine —
> did not survive being tested. Langfuse now runs here in the `langfuse` namespace at ~1.6 GiB
> idle. See ADR 0008 and `platform/observability/langfuse/README.md`. The original reasoning
> is kept below because the way it failed is instructive.

The workshop uses Langfuse. Self-hosted Langfuse (v4) is **six containers** — web, worker,
ClickHouse, MinIO, Redis, Postgres — with official sizing guidance of 4 cores / 16 GiB. There
is no lightweight or Postgres-only path; the v2 line that needed only Postgres is gone.

This machine is a 24 GB Mac whose Docker VM gets **11.7 GiB**, and the k3d cluster already
uses ~2 GiB before Ollama loads a model on the host. Langfuse would starve everything else.

**What that costs, precisely:** Langfuse's LLM-specific UI — prompt/completion rendering,
token cost attribution, prompt management. That is genuinely useful and it is the part not
reproduced here.

**What it does not cost:** the mechanism lab 2 teaches. Zero-code auto-instrumentation, W3C
`traceparent` propagation, and the collector-as-sole-egress pattern are all OpenTelemetry
properties, not Langfuse properties. Any OTLP backend shows them. Swapping back is an exporter
block in `platform/observability/otel-collector.yaml` and nothing else — which is itself the
point of putting a collector in the middle.

Langfuse remains worth running on a 64 GB machine, where it fits.

**Two errors, of different kinds.** The 11.7 GiB was a misread: this machine runs OrbStack,
not Docker Desktop, and that figure is a configurable soft cap over dynamically allocated
memory, not a fixed VM ceiling. And 16 GiB was treated as a requirement when it is a
production sizing recommendation. The second error is the one worth carrying forward — a
vendor's recommended sizing describes their expected load, not the software's floor, and the
gap between the two was roughly a factor of eight here.

Jaeger remains the collector's live export target, now by preference rather than necessity.

## What works

A single chat turn produces one coherent trace:

```
POST /chat                          [customer-agent]
  invoke_agent Strands Agents
    execute_event_loop_cycle
      chat                          <- gen_ai.operation.name
        POST                        <- outbound call to the gateway
    execute_tool lookup_order
    execute_event_loop_cycle
      chat
```

Strands emits proper **GenAI semantic-convention** spans (`gen_ai.operation.name`,
`gen_ai.agent.name`, `gen_ai.user.message`, `gen_ai.choice`), so the trace is richer than a
bare HTTP waterfall. No tracing code exists in the agent — `opentelemetry-instrument` in the
Dockerfile CMD does all of it.

## A finding worth keeping: streaming defeats naive auto-instrumentation

The first working trace had **543 spans** for one question. The ASGI middleware opens a span
per SSE chunk, so ~530 of them were `POST /chat http send` carrying nothing, burying the six
spans that mattered.

Fixed with a `filter` processor in the collector, not in the app — **telemetry shaping is
policy, and policy belongs at the control point**. One collector rule fixes it for every
workload that will ever stream, which is the same argument lab 4 makes about authorization.
Result: 543 spans → 9.

## The gateway-span gap: mostly fixed, and I had the cause wrong

The original text here said "spans leave Envoy and never land" and pointed at Envoy. That was
wrong in an instructive way. Three separate things were tangled together.

### 1. Transport — FIXED

The `tracing` cluster Envoy Gateway generates carried **no `http2_protocol_options`**. OTLP
gRPC requires HTTP/2, so Envoy was speaking gRPC over HTTP/1.1 and the collector's gRPC
receiver rejected every stream. That produced a genuinely misleading symptom set: Envoy
reported `spans_sent` incrementing and `spans_dropped: 0` (it *had* sent them), the endpoint
showed `eds_health_status: HEALTHY`, and the collector logged nothing at all — because it never
saw a valid gRPC stream to log about.

The fix is one field, on the collector's **Service**, not on Envoy:

```yaml
- {name: otlp-grpc, port: 4317, targetPort: 4317, appProtocol: grpc}
```

Envoy Gateway infers upstream protocol from `appProtocol`. With it, the cluster gains
`http2_protocol_options`, `cluster.tracing.internal.upstream_rq_5xx` stops incrementing and
`upstream_rq_2xx` starts, and `envoy-ai-gateway.default` appears in Jaeger. Verified.

### 2. Envoy honours inbound trace context — PROVEN, never the problem

Tested directly by sending a hand-written header through the gateway:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
  -> gateway continued the supplied trace: 4 spans under 4bf92f35...
```

So the component I spent the most time suspecting was behaving correctly the whole time.

### 3. RESOLVED — the trace does join

Verified 2026-08-16 against Langfuse. One `/chat` turn produces **one trace with 26
observations**, containing both services:

```
POST /chat                                      [agent, FastAPI]
  invoke_agent Strands Agents
    execute_event_loop_cycle  x2
      chat  x2
    lookup_order
  ingress                                   x2  [Envoy]
  router httproute/default/local/rule/1 egress  x2  [Envoy]
  async envoy.service.ext_proc.v3.ExternalProcessor.Process egress  x4  [AI Gateway extproc]
```

That is the workshop's headline lab-2 property — the gateway's work nesting under the agent's
trace via `traceparent` — reproduced in full.

**It was fixed by the `appProtocol: grpc` change in part 1.** Nothing else was needed. Two
earlier claims in this ADR were wrong and are withdrawn:

- *"the agent trace regressed from 9 spans to 2."* It did not. I was reading Jaeger, which was
  later deleted, and querying stale traces. The live trace has 26 observations.
- *"leading hypothesis: `strands-agents[otel]` installs its own TracerProvider and races
  `opentelemetry-instrument`."* It does not. `strands.telemetry.tracer` calls
  `trace_api.get_tracer_provider()` and never constructs or sets one, so there is no race.

**The compounding error worth naming:** I declared an open gap, wrote a hypothesis for it, and
carried it in an ADR — all while measuring against a backend I had since removed from the
cluster. Re-verify a "known gap" before writing the next theory about it, especially after
changing the thing you measure with.

## Method note

The Envoy admin API was reached by **port-forwarding to the pod**, not by `kubectl exec ... curl`
— there is no `curl` in that container, and an earlier attempt to use it returned 0 bytes and
produced a confidently wrong conclusion (see ADR 0002). Port-forward and query from the host.
