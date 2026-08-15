# ADR 0008 — Langfuse fits after all, at 1.6 GiB

**Status:** accepted
**Date:** 2026-08-15
**Supersedes:** the backend-substitution half of ADR 0004

## Decision

Run Langfuse locally, in the `langfuse` namespace, tuned to ~1.6 GiB idle and ~2.0 GiB under
load. Keep Jaeger as the OTel collector's live export target; ship the Langfuse exporter as a
documented, commented block in `platform/observability/otel-collector.yaml` that can be
enabled alongside Jaeger rather than instead of it.

Manifests: `platform/observability/langfuse/{00-namespace-and-secrets,10-datastores,20-langfuse}.yaml`.
Full detail and reproduction steps: `platform/observability/langfuse/README.md`.

## Context

ADR 0004 substituted Jaeger for Langfuse on the grounds that Langfuse needs 4 cores / 16 GiB
and this machine's container VM had only 11.7 GiB. Both halves of that were wrong.

**The 11.7 GiB was a misread.** This machine runs OrbStack, not Docker Desktop. `orb config
show` reports `memory_mib: 12288`, a *configurable soft cap* over dynamically allocated
memory. With the full cluster plus all of Langfuse running, the OrbStack helper's measured
host RSS was 1.6-3.7 GiB — nowhere near the cap. No OrbStack reconfiguration was needed and
none was made.

**The 16 GiB is a production recommendation, not a floor.** It comes from expected ingest
rate and from default cache sizing, not from anything structural. The official Helm chart is
worse than the docs — ClickHouse defaults to `resourcesPreset: 2xlarge` at
`replicaCount: 3`, requesting ~9 GiB by itself — and no upstream minimal or dev profile
exists, so the tuning had to be done by hand.

## What made it fit

All six containers still run. Langfuse genuinely requires web, worker, Postgres, ClickHouse,
Redis, and blob storage; the Postgres-only path was a v2 feature and is gone, and
`LANGFUSE_S3_EVENT_UPLOAD_*` has no disable flag because it is the ingestion path itself. The
topology was never the expensive part.

**One root cause covers most of the savings: ClickHouse, MinIO, and Node all size their
memory from host RAM and none of them read the cgroup limit.** They each saw ~11.7 GiB and
helped themselves — ClickHouse reserving a 5 GiB mark cache, Node targeting a 1.7 GiB heap —
while their container limits sat unread. Every fix is the same fix: state the number
absolutely rather than letting the process infer it.

The largest levers were `mark_cache_size` 5 GiB → 128 MiB, `CLICKHOUSE_CLUSTER_ENABLED=false`
(which removes the ClickHouse Keeper container entirely), and disabling ClickHouse's ~10
`system.*_log` self-telemetry tables, which dominate idle RSS and disk churn on a dev node.
ClickHouse settled at **86 MiB idle** against its 2 GiB limit.

## Gotchas worth recording

**Shrinking ClickHouse's background pool crashes it at startup.** ClickHouse asserts
`number_of_free_entries_in_pool_to_execute_mutation <= background_pool_size *
background_merges_mutations_concurrency_ratio`. Those `merge_tree` defaults are sized against
a core-count-derived pool; lowering the pool without lowering them exits `BAD_ARGUMENTS`
before the server ever listens. A hard exit, not a warning.

**"OOM" is two distinct failures.** Raising langfuse-web's container limit without raising
`--max-old-space-size` left it crash-looping anyway: V8 hit its own 768 MB ceiling and died
with `FATAL ERROR: Ineffective mark-compacts near heap limit` while a third of the container
limit went unused. The container limit and the heap cap are a pair. `kubectl` reports the
first as `OOMKilled` and the second as plain `Error`, which is how to tell them apart.

**Redis must run `maxmemory-policy noeviction`**, or BullMQ queue keys can be evicted and
spans are lost silently rather than failing loudly.

**arm64 was a non-issue.** Every image was verified with `docker manifest inspect` before
deploying; langfuse, langfuse-worker, clickhouse-server, minio, redis, and postgres all
publish arm64. This was the most plausible hard blocker and it did not materialize.

## Consequences

The feature loss ADR 0004 accepted is recovered: the LLM-specific UI, prompt/completion
rendering, token cost attribution, and prompt management are all present, which matters
because Langfuse familiarity is a deliberate learning goal here and Jaeger does not build it.

**The one real trade is sustained ingest throughput.** 2000 telemetrygen traces at 4 workers
ingested 819 in 6m40s without dropping data or restarting a pod, but did not keep up in real
time. Irrelevant at demo scale — a person asking an agent questions — and the ClickHouse pool
and cache settings are where to give memory back if throughput ever matters.

Also accepted, all appropriate for a local demo: single replica of everything, no HA, no
Keeper, in-repo plaintext secrets, batch export disabled.

Jaeger stays wired by default so the existing lab 2 notes keep matching what the collector
does. Because an OTLP pipeline fans out to every exporter it names, both backends can receive
identical spans and be compared directly — which is a better demonstration of the
collector-as-control-point argument than either backend alone.

## The generalizable lesson

A vendor's recommended sizing describes their expected production load, not the software's
minimum. Here the gap was a factor of eight. It cost one afternoon to measure, and the
measurement was only possible because the substitution had been written down in ADR 0004
with its reasoning exposed — which is what made the premise checkable later.
