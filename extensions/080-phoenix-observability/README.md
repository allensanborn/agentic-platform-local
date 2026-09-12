# 080 — Arize Phoenix as the trace backend

**Seam:** `observability` · **Status:** proposed
**Base required:** labs 0-2 (`make observability`; the collector is the control point)
**Requires extensions:** none
**Alternative to:** Langfuse (same seam — pick one per cluster, or run both briefly for the comparison shot)

## What this demonstrates

Lab 2's control point is the **collector**: every workload speaks plain OTLP to it and holds no credential for the tracing backend. That design *is* the seam — the backend behind the collector is an exporter config, not an application change. This extension proves it by swapping Langfuse for **Arize Phoenix**, the open-source (ELv2) LLM/agent observability and evaluation platform: OTel-native tracing via the **OpenInference** semantic conventions, LLM evals (including LLM-as-judge), annotation, datasets/experiments, and a prompt IDE.

What Phoenix adds beyond a backend swap, and why it earns an extension rather than a footnote: the base has traces but **no evaluation story**. Phoenix's datasets-from-traces → experiments loop turns lab 2's spans into an eval harness — score the agent's answers on the workshop's own order-question set, then use it as the regression gate the repo's eval tier (`tests/evals`, ADR 0012) currently approximates by hand.

## The substitution

| | Base | This extension |
|---|---|---|
| `observability` | Langfuse (hand-tuned to ~1.6 GiB; OTLP in via collector) | Phoenix (single container + Postgres; OTLP in via the same collector) |

Preserved: the collector, every workload's OTLP config, the no-tracing-credential property, span shape at the emit side. Cost: Langfuse's LLM-specific UI niceties (token cost attribution, prompt management UX) differ — document the deltas honestly; and the nested-trace fidelity that lab 2 fought for (the 26-observation single trace, gateway span under agent span) must be re-verified, since Phoenix reads OpenInference conventions and the base emits vanilla OTel GenAI spans. That mapping is the finding, whichever way it goes.

## Plan

1. Base up through lab 2; capture the 26-observation trace as the before.
2. Phoenix on the cluster; point a *second* collector exporter at it (dual-write) — zero risk to the base while comparing.
3. Compare the same `/chat` turn in both UIs: span nesting, gateway-under-agent join, token/cost attribution. Record deltas.
4. Flip: remove the Langfuse exporter, Phoenix becomes the backend; base verify still green.
5. The payoff step: build a dataset from captured traces, run one experiment (e.g. `local-fast` vs `local-smart` on the order-question set) — the lab-0 alias flip, now *measured* instead of demonstrated.

## Verify

- one `/chat` turn produces a single joined trace in Phoenix (agent + gateway spans nested, not two orphan traces — lab 2's regression, re-run against the new backend)
- no workload gained a credential: the collector remains the only thing that knows Phoenix exists
- **positive control:** during dual-write, the same trace ID appears in both backends
- an experiment run scores both model aliases on the same dataset and the report renders

## Grounding

wiki: `arize-phoenix` (five capabilities; OpenInference as an OTel convention layer for LLM spans), `arize` (entity; AX is the managed counterpart), `langfuse-overview`, `automated-evaluation` / `agent-evaluation` (the LLM-grades-an-LLM pattern this productizes), `opentelemetry`. Base context: ADR 0008 (Langfuse sizing), ADR 0012 (the eval tier this extension gives a real harness).
