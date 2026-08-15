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

## Known gap: the gateway's span does not join the trace

The workshop's headline detail is that the gateway's `ChatCompletion` span **nests under** the
agent's trace via `traceparent`, making one turn a single tree across two services. That is
not reproduced. Diagnostic state, so the next attempt starts informed:

- Envoy Gateway telemetry **is** configured (`EnvoyProxy.spec.telemetry.tracing`,
  `samplingRate: 100`, OTLP to the collector) and the controller generates a `tracing` cluster.
- The cross-namespace `ReferenceGrant` is accepted; the endpoint resolves and reports
  `eds_health_status: HEALTHY`.
- Envoy **is** exporting: `tracing.opentelemetry.spans_sent` increments (8 → 12 across one
  request), `spans_dropped: 0`.
- But `cluster.tracing.internal.upstream_rq_5xx: 3` and
  `upstream_cx_destroy_local_with_active_rq: 3` — Envoy tears the connection down mid-request.
- The collector logs **no** error and receives **no** span with a non-`customer-agent`
  `service.name`.

So spans leave Envoy and never land. Next things to try: OTLP HTTP instead of gRPC; whether
Envoy's exporter needs a `service.name` resource attribute the collector will accept; and
whether the collector's gRPC receiver needs `max_recv_msg_size` or compression settings.

## Method note

The Envoy admin API was reached by **port-forwarding to the pod**, not by `kubectl exec ... curl`
— there is no `curl` in that container, and an earlier attempt to use it returned 0 bytes and
produced a confidently wrong conclusion (see ADR 0002). Port-forward and query from the host.
