# Langfuse, tuned to fit a laptop

Lab 2's original observability backend, running locally after all. ADR 0004 dropped it for
Jaeger on the belief that it needed 16 GiB. That belief was wrong; this directory is the
correction.

**Verdict: it fits, comfortably. 1.6 GiB idle, 2.0 GiB under load, on a 24 GB Mac, with
nothing given up except sustained ingest throughput.**

## Apply

```sh
kubectl apply -f platform/observability/langfuse/00-namespace-and-secrets.yaml
kubectl apply -f platform/observability/langfuse/10-datastores.yaml
kubectl apply -f platform/observability/langfuse/20-langfuse.yaml
kubectl -n langfuse rollout status deploy/langfuse-web --timeout=300s

kubectl port-forward -n langfuse svc/langfuse-web 3000:3000
# http://localhost:3000  —  admin@anycompany.local / langfuse123
```

Cold start is a few minutes: langfuse-web runs 424 Prisma migrations plus the ClickHouse
migrations before it serves.

## Measured footprint

Steady state after ingesting 819 traces / 1638 observations, all six pods, zero restarts:

| Container | Idle | After load | Limit |
|---|---|---|---|
| langfuse-web | 875 Mi | 974 Mi | 1536 Mi |
| langfuse-worker | 313 Mi | 406 Mi | 768 Mi |
| minio | 252 Mi | 327 Mi | 512 Mi |
| clickhouse | 86 Mi | 252 Mi | 2048 Mi |
| postgres | 48 Mi | 44 Mi | 512 Mi |
| redis | 16 Mi | 11 Mi | 256 Mi |
| **total** | **~1.6 GiB** | **~2.0 GiB** | 5.5 GiB |

Sum of *requests* is 1.44 GiB, which is what the scheduler actually reserves.

Note how far ClickHouse lands from its own limit. The upstream "16 GiB" number is not
describing a floor that ClickHouse needs to function; it is describing default cache sizing
plus a production ingest rate. Pin the caches and the idle cost is 86 Mi.

## Why the official guidance says 16 GiB, and why it does not bind here

Langfuse's docs recommend 4 cores / 16 GiB, and the official Helm chart is worse: ClickHouse
defaults to `resourcesPreset: 2xlarge` (3 GiB request, 12 GiB limit) times `replicaCount: 3`,
so the chart alone *requests* about 9 GiB. There is no upstream minimal or dev profile. A
maintainer has said 8 GiB "is really at the lower end."

Every one of those numbers assumes production ingest. The topology is not the expensive part:
all six containers still run here. What was removed is default cache sizing and cluster mode.

**One theme explains nearly all of it.** ClickHouse, MinIO, and Node each size their memory
from *host* RAM and none of them read the cgroup limit. On this machine they saw ~11.7 GiB
and helped themselves accordingly — ClickHouse reserving a 5 GiB mark cache, Node targeting a
1.7 GiB heap — while their container limits sat there unread. Every fix below is the same
fix: state the number absolutely instead of letting the process infer it. This is worth
internalizing beyond Langfuse; it is why "just set a memory limit" so often fails to contain
a container.

The levers, in order of how much they saved:

1. **`mark_cache_size` 5 GiB → 128 MiB.** Allocated eagerly, and the single biggest win.
2. **`CLICKHOUSE_CLUSTER_ENABLED=false`.** Default-true issues all DDL `ON CLUSTER`, which
   requires ClickHouse Keeper — a seventh container and roughly another 500 MiB. False runs
   migrations against the single node. Single-replica, no Keeper, no ZooKeeper.
3. **ClickHouse `system.*_log` tables disabled.** A default ClickHouse writes ~10 self-
   telemetry tables, each with a flush buffer and MergeTree parts to merge. On an idle dev
   node that is most of the idle RSS and disk churn, and none of it is Langfuse data.
4. **`max_server_memory_usage` = 1.4 GB, absolute.** Deliberately not a `*_to_ram_ratio`
   knob, which would re-derive from the host figure that caused the problem. Held under the
   container limit so a runaway query raises a ClickHouse exception instead of taking a
   SIGKILL mid-merge. A failed query is debuggable; an OOMKill is not.
5. **`NODE_OPTIONS=--max-old-space-size`** on web and worker (see the trap below).
6. **MinIO `--memlimit`.** Same host-RAM-sizing story; 295 MiB idle against a 512 Mi limit
   before the flag.

## Traps worth remembering

**Shrinking ClickHouse's background pool crashes it at startup.** ClickHouse asserts

```
number_of_free_entries_in_pool_to_execute_mutation
  <= background_pool_size * background_merges_mutations_concurrency_ratio
```

Those `merge_tree` defaults (20 / 8 / 25) are sized against a `background_pool_size` derived
from core count. Setting the pool to 4 makes the right side 8, the assertion fails, and the
server exits `BAD_ARGUMENTS` before it ever listens. A hard exit, not a warning. Anyone
lowering the pools has to lower these in the same edit.

**"OOM" is two different failures that look alike.** Raising langfuse-web's container limit
to 1536Mi *without* raising `--max-old-space-size` past 768 left it crash-looping anyway:
V8 hit its own ceiling and killed itself with `FATAL ERROR: Ineffective mark-compacts near
heap limit` while a third of the container limit sat unused. The container limit and the heap
cap are a pair and must move together. `kubectl` shows the container-limit version as
`OOMKilled` and the V8 version as plain `Error`, which is the fastest way to tell them apart.

**Blob storage is not optional.** MinIO cannot be dropped. Langfuse writes every incoming
event to S3 before the worker consumes it, and `LANGFUSE_S3_EVENT_UPLOAD_*` has no `ENABLED`
flag, unlike media upload and batch export (both off here). It is the ingestion path itself.
It is also the cheapest thing in the stack, so this costs little. Redis and ClickHouse are
likewise required; the Postgres-only deployment was a v2 feature and is gone.

**Redis must use `maxmemory-policy noeviction`.** Langfuse runs its ingestion queue through
BullMQ. Under any eviction policy Redis may drop queue keys, which silently loses spans
rather than failing loudly.

**MinIO path-style addressing.** `LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE=true`, or the SDK
builds virtual-host `bucket.langfuse-minio...` names that do not resolve.

**Two ClickHouse URLs.** `CLICKHOUSE_URL` is HTTP (8123) for the app; `CLICKHOUSE_MIGRATION_URL`
is the native protocol (9000) for the migrator. Getting this wrong surfaces only as a
migration failure at boot.

**arm64: a non-issue.** Every image was checked with `docker manifest inspect` before
deploying — langfuse/langfuse, langfuse-worker, clickhouse-server (alpine), minio, redis,
postgres all publish arm64. This was the most plausible hard blocker and it did not
materialize.

Benign noise: ClickHouse logs `Address already in use` for 9009/8123/9000 at startup. It
binds `::` first, which already covers IPv4. Confirmed harmless — `/ping` returns 200 and
queries work.

## What was actually given up

**Sustained ingest throughput, and nothing else.** All Langfuse features are present: the
LLM-specific UI, prompt/completion rendering, token cost attribution, prompt management,
datasets, evals. The feature loss that ADR 0004 accepted by moving to Jaeger is fully
recovered.

The cost is rate. A `telemetrygen` run of 2000 traces at 4 workers ingested 819 within 6m40s
without dropping anything or restarting a pod, but it did not keep up in real time. For
demo-scale traffic — a person asking an agent questions — this is irrelevant. For a load test
it would be the bottleneck, and ClickHouse's pool and cache settings are where to give memory
back.

Also given up, all appropriate for a local demo: no HA, single replica of everything, no
Keeper, in-repo plaintext secrets, and batch export disabled.

## Host memory context

The 11.7 GiB figure in ADR 0004 was a misreading. This machine runs **OrbStack**, not Docker
Desktop, and `orb config show` reports `memory_mib: 12288` — a *configurable soft cap*, not a
fixed VM allocation. OrbStack allocates dynamically: with the cluster plus all of Langfuse
running, the OrbStack helper's host RSS was measured at 1.6-3.7 GiB, nowhere near the cap.

So no OrbStack reconfiguration was needed, and `orb config set memory_mib` was deliberately
left alone. Budget on a 24 GB host: ~2 GiB Langfuse + ~3 GiB existing cluster + ~6 GiB Ollama
with a model loaded still leaves substantial headroom, and the cap could be raised to ~16 GiB
if it were ever needed.

## Wiring the OTel collector to Langfuse

`platform/observability/otel-collector.yaml` has a ready `otlphttp/langfuse` exporter block,
commented out. Jaeger remains the live export target; uncommenting adds Langfuse alongside it
so both receive identical spans. Endpoint and Basic-auth header shape are documented there
and were verified end to end.
