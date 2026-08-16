# ADR 0012 — Testing and evaluation strategy: four layers, one new dependency

**Status:** proposed
**Date:** 2026-08-16
**Related:** [ADR 0003](0003-reasoning-tokens.md) (reasoning tokens), [ADR 0004](0004-observability-backend-and-gateway-spans.md) (the lab-2 trace), [ADR 0007](0007-tool-call-token-budget.md) (silent tool-call failure), [ADR 0008](0008-langfuse-fits-after-all.md) (Langfuse is deployed)

## Decision, in one paragraph

Adopt **exactly one new tool: promptfoo**, driving the agent's own `/chat` SSE endpoint through a custom Python provider, with assertions computed from `data/orders.json` at test time. Keep **Langfuse** as the trace store and the forensic surface — and, for lab 2 and for tool *results*, as a queryable oracle — but **not** as the test runner. Keep **plain pytest** for everything model-free. Adopt **neither DeepEval, nor Ragas, nor Testkube, nor Tracetest**. The organising rule is: *a judge is itself a model that can regress, so a judge is the last resort, and here it is very nearly never needed.*

## Why this repo is an unusually easy evaluation target

Three properties, all verified rather than assumed:

1. **Ground truth is a file in the repo.** `data/orders.json` is 500 fixed rows. The lab-5 headline numbers reproduce from it in ten lines:

   ```
   $ python3 -c "..."   # group 2026-Q1 by region, Decimal sums
   2026-Q1 rows: 139
   Central 17494.04   East 16014.34   South 25758.73   West 34793.56
   ```

   That matches the README's claimed figures exactly. **Consequence:** expected outputs must be *computed from the seed file at test time*, never hand-copied into a fixture. A re-seed can then never silently invalidate the eval set.

2. **The wire contract already exposes the agent's internal structure.** `modules/200-agent/customer-agent/server.py` streams four event kinds: `{"token"}`, `{"reasoning"}`, `{"tool_use": {id, name, input}}`, `{"tool_result": {id, status}}`. Tool *selection* and tool *arguments* are on the wire. This is the single most important fact in this document — see "Agent-level vs model-level evaluation" below.

3. **A model-free control already exists.** `modules/900-sandbox/probe.py` drives the broker over MCP with no model in the path, precisely so "a flaky model must not be mistaken for a broken broker." That separation of oracles is the layering this ADR generalises.

**Not verified in this session:** the live cluster was unreachable (`kubectl` and `docker ps` both timed out), so every claim below rests on the manifests, the source, and vendor documentation rather than on a running system. The Langfuse API shapes in particular are cited to upstream docs and should be re-checked against the local 3.225.2 deployment before code is written.

## The four layers

Each layer has a different oracle, a different runtime, and a different failure meaning. Conflating them is the trap the epic names.

### Layer 0 — unit tests. Oracle: pytest. Model: absent.

Already exists and already passes: `make sandbox-unit` (broker) and `make coding-unit` (dispatcher), 525 lines across 8 files. **Change needed: none, except an aggregating `make test-unit` and actually running it.** No new tooling.

### Layer 1 — infra / control-point assertions. Oracle: the cluster. Model: absent.

This is the layer that answers "does the platform still enforce what it claims." It exists today as *demos that print* rather than *tests that assert*: `sandbox-airgap`, `coding-egress-check`, `coding-token-check`, `sandbox-test` all produce human-readable output and exit 0 regardless. Converting them is mechanical — each already has a machine-checkable expectation embedded in its prose:

| Claim | Assertion | Where it must run |
|---|---|---|
| deny-by-default per-tool authz | `tools/list` as `sam` excludes `run_python` and `check_inventory`; as `ana` excludes `initiate_return` | host, via port-forward |
| no token → 401 | unauthenticated MCP call returns HTTP 401 at the gateway | host |
| sandbox air-gap | outbound connect fails **and** the control pod's identical probe succeeds | **inside the cluster** |
| no service-account token | `/var/run/secrets/kubernetes.io` absent in sandbox, present in control | **inside the cluster** |
| coding-agent egress lock | gateway + Gitea reachable, kube API + `openrouter.ai` blocked | **inside the cluster** |
| token revocation | minted token authenticates, then 401 after the run | host |
| gVisor is actually in use | `uname -r` contains `gvisor` | inside |

Note the **control pod** pattern already used in `sandbox-airgap`: a "blocked" result proves nothing unless the same probe from an unselected pod connects. That negative control belongs in the assertion, not in the commentary — a NetworkPolicy that blocks everything because the cluster has no egress at all would otherwise pass.

**Runtime:** the in-cluster half already works by `kubectl run` / `kubectl exec` from the host. That is sufficient. See "Testkube" below for why it stays that way.

### Layer 2 — structural assertions (lab 2). Oracle: the Langfuse API. Model: irrelevant.

Lab 2's property is not behavioural: *the gateway's spans nest under the agent's trace*. Asserting it needs the trace, and the trace lives in Langfuse.

This is not an exotic thing to hand-roll. The OpenTelemetry Demo's own CI does exactly this: `test/telemetry/test_traces_edges.py` is a pytest suite that queries the trace store and asserts a directed parent→child edge between two named services ([opentelemetry-demo test/telemetry](https://github.com/open-telemetry/opentelemetry-demo/blob/main/test/telemetry/test_traces_edges.py)). Its own note is worth stealing: query by the **child** service, because a high-volume parent floods the result window.

The correlation key is already there and is better than scraping a trace ID off a response: `agent.py` sets `trace_attributes={"session.id": session_id}`, and `ask.sh` already generates a fresh UUID session per run. So a test drives one `/chat` turn with a known session ID, then polls Langfuse for the trace carrying it. (The stricter alternative — have the test client generate its own `traceparent` and inject it on the `/chat` request, then fetch by trace ID — removes the search step entirely and is worth doing if session lookup proves flaky. ADR 0004 already proved by hand that Envoy honours an inbound `traceparent`.)

Sketch (Langfuse public API, HTTP Basic over `pk-lf-agentic-platform-local:sk-lf-agentic-platform-local`, per `platform/observability/otel-collector.yaml`):

```python
# Poll — OTLP export is asynchronous and batched, so the trace is not there when /chat returns.
def wait_for_trace(session_id, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = get("/api/public/v2/traces", params={"sessionId": session_id})
        if r["data"]:
            return r["data"][0]["id"]
        time.sleep(2)
    raise AssertionError(f"no trace for session {session_id} within {timeout}s")

def test_gateway_spans_nest_under_the_agent_trace():
    sid = f"eval-{uuid4()}"
    ask(user="ana", question="My order ID is ORD-1001. Where is it?", session_id=sid)
    obs = get(f"/api/public/v2/traces/{wait_for_trace(sid)}")["observations"]

    by_id = {o["id"]: o for o in obs}
    def ancestors(o):
        # Walk parentObservationId to the root; a trace is a forest of at most one tree here.
        while o.get("parentObservationId"):
            o = by_id[o["parentObservationId"]]
            yield o

    def find(pred):
        return [o for o in obs if pred(o)]

    root = find(lambda o: o["name"].startswith("POST /chat"))
    assert len(root) == 1, "expected exactly one /chat root span"

    # The lab-2 property: an Envoy span exists AND descends from the agent's root.
    envoy = find(lambda o: "envoy.service.ext_proc" in o["name"] or o["name"].startswith("router "))
    assert envoy, "no gateway spans in the trace — traceparent propagation is broken"
    assert any(root[0]["id"] == a["id"] for a in ancestors(envoy[0])), \
        "gateway spans exist but form a separate tree — the trace did not join"

    # The SSE-chunk filter is itself a control point worth regressing (ADR 0004: 543 -> 9 spans).
    assert not find(lambda o: o["name"] == "POST /chat http send"), \
        "collector filter/drop_sse_chunk_spans is not dropping SSE chunk spans"
```

That is roughly forty lines of pytest and one dependency (`httpx`). Six pitfalls to design around, all real:

- **Timing is the number-one flake source.** `BatchSpanProcessor` buffers (`OTEL_BSP_SCHEDULE_DELAY`, 5 s default), the collector's `batch` processor buffers again, and Langfuse ingests through a queue and a worker. Poll with a timeout; never `sleep(3)` and hope. Poll on the *strongest* condition — both services present — not merely "a trace exists," or a half-ingested trace fails the parentage assertion and looks exactly like a propagation bug.
- **A partial trace is not a negative result.** If a `parentObservationId` points at an observation that has not landed yet, retry; do not assert false.
- **Span-name instability.** `execute_event_loop_cycle`, `router httproute/default/local/rule/1 egress`, and `async envoy.service.ext_proc.v3.ExternalProcessor.Process egress` are all library-version artefacts. Assert on *substrings and parentage*, not on exact names, or the test becomes a dependency-upgrade tripwire rather than a lab-2 test.
- **Do not assert an exact observation count.** ADR 0004's "26 observations" is a Langfuse-side artefact of how it remodels OTLP into typed observations, not a property of our system. It will drift on a Langfuse upgrade. (An *upper bound* as a guard against the 543-span regression is defensible; an equality check is not.)
- **`isRootObservation` is not the same as "no parent."** Langfuse documents it as true for physical roots *and* for app roots whose SDK parent is external — so `parentObservationId` can be non-null on a "root." Find our root by name, not by that flag.
- **The negative assertion matters most.** ADR 0004 records that this exact property was believed broken for a while, and that the diagnosis was wrong twice. The assertion that catches the real regression is "an Envoy span exists *and is a descendant*" — two disconnected trees is the failure mode, and a naive "the trace has spans from two services" check passes in that broken state.

Two API details to build behind a one-function adapter: auth is HTTP Basic with the public key as username and the secret key as password ([langfuse.com/docs/api](https://langfuse.com/docs/api)), and **`GET /api/public/traces/{traceId}` is deprecated with a stated removal date of 2026-11-16**, superseded by `GET /api/public/v2/observations?traceId=…`. On that v2 endpoint the `core` field group always includes `parentObservationId`, but `name` lives in `basic` — request `fields=core,basic`.

A cheap **tier-0 companion** worth adding at the same time: an in-process pytest using `InMemorySpanExporter` inside the agent, asserting that the `/chat` server span parents the outbound HTTP client span and that the injected `traceparent` carries the same trace ID. It cannot see Envoy — so it cannot test the lab-2 property — but it catches most propagation regressions in milliseconds with no cluster at all.

One live-configuration note in our favour: `platform/gateway/ai-gateway.yaml` sets `telemetry.tracing.samplingRate: 100`, so Envoy is not sampling gateway spans away. Envoy's sampling is independent of the OTel SDK's; if gateway spans go missing, check that field before suspecting `traceparent`.

### Layer 3 — behavioural evals with ground truth. Oracle: `data/orders.json`. Model: the thing under test.

This is the layer that has nothing today, and the layer the model matrix runs at. Tooling: **promptfoo**. Detail below.

### Layer 4 — judged evals. Oracle: another model.

**Budget: as close to zero as possible.** The only behaviour here that superficially needs a judge is lab 4's "declines gracefully rather than hallucinating the capability" — and even that decomposes into a deterministic part and a stylistic part:

- *deterministic:* no `tool_use` event named `run_python` appeared, **and** the answer contains none of `17494.04 / 16014.34 / 25758.73 / 34793.56 / 139` — numbers the model could only have obtained by running the tool. That is a falsifiable hallucination check with no judge in it.
- *stylistic:* "is the refusal warm and professional." Real, but not a regression signal worth a model dependency. Leave it to the human watching the demo.

Same logic applies to lab 5's injection-refusal cases: the assertion is "no `run_python` call containing the injected instruction, and no leaked path/secret in the output," not "did it refuse politely."

## The tooling verdicts

### promptfoo — ADOPT, as the layer-3 runner

**What it is for here:** the model matrix, and per-chapter behavioural regression with deterministic assertions.

- **It can drive our agent, not just a model.** The `http`/`https` provider takes a templated JSON body and a `transformResponse`, and the docs have an explicit SSE section: promptfoo hands the transform the *entire buffered body* as `text` and you reassemble the `data:` lines yourself ([http provider](https://www.promptfoo.dev/docs/providers/http/)). So `/chat` is drivable out of the box. We should nonetheless use the **Python custom provider** (`file://provider.py`, `call_api(prompt, options, context) -> {"output", "metadata", ...}` — [python provider](https://www.promptfoo.dev/docs/providers/python/)) because we need to mint a Keycloak token per persona first, and because we want the parsed tool calls in `metadata`.
- **Assertions can be fully deterministic.** `equals`, `contains-all`, `regex`, `is-json`, `levenshtein`, and — the one that matters — `python` / `javascript` asserts receiving `output` plus a context carrying `vars`, `test`, `providerResponse`, `metadata`, and `trace` ([deterministic metrics](https://www.promptfoo.dev/docs/configuration/expected-outputs/deterministic/), [python asserts](https://www.promptfoo.dev/docs/configuration/expected-outputs/python/)). Any type can be negated with a `not-` prefix. Our ground-truth check is a `python` assert that recomputes the answer from `data/orders.json`.
- **Comparison output.** `promptfoo eval -o results.json -o results.html -o junit.xml`; formats include csv/json/jsonl/yaml/html/xml/junit.xml; `promptfoo view` renders the providers × tests matrix with a Failures/Different filter and an eval-diff view ([CLI](https://www.promptfoo.dev/docs/usage/command-line/), [web UI](https://www.promptfoo.dev/docs/usage/web-ui/)).
- **CI ergonomics.** Non-zero exit on failure — **exit code 100, not 1**, overridable with `PROMPTFOO_FAILED_TEST_EXIT_CODE`, plus `PROMPTFOO_PASS_RATE_THRESHOLD`. `--repeat N` for variance. `-j/--max-concurrency` (default 4).

**Three defaults that must be changed or this harness lies to us:**

1. **`cache: true` is the default.** A cached response cannot regress. `--no-cache` on every eval run, always.
2. **`validateStatus` accepts every status code by default.** A 500 from the agent otherwise becomes an "output" that fails a content assertion with a misleading reason. Set it explicitly.
3. **`promptfoo share` snapshots include provider configuration fields.** Set `PROMPTFOO_DISABLE_SHARING=true`; there is no reason to upload this.

**Where promptfoo stops:** it is not an agent debugger. When a case fails you get a string, a score, and a boolean. *Why* it failed — which turn burned the token budget, what the tool actually returned, whether the gateway 429'd — is in Langfuse. The two tools are complementary and neither replaces the other.

**Deliberately not using promptfoo's `trajectory:*` assertions, at least not first.** They are genuinely well-suited on paper (`trajectory:tool-used`, `trajectory:tool-args-match` with an exact mode that catches hallucinated extra arguments, `trajectory:tool-sequence`, `trajectory:step-count` — [deterministic metrics](https://www.promptfoo.dev/docs/configuration/expected-outputs/deterministic/)), and promptfoo runs its own OTLP receiver on :4318 and propagates `traceparent` into the provider ([tracing](https://www.promptfoo.dev/docs/tracing/)), so the collector could fan out to it with one exporter block — the same collector-as-control-point move ADR 0004 already makes. **But** trajectory assertions read tool names from attributes named `tool.name` / `function.name` / `ai.toolCall.name`, and Strands emits GenAI-semconv spans (`gen_ai.*`, tool spans named `execute_tool lookup_order` per ADR 0004). **Whether those line up is unverified**, and if they do not, the fix is an attribute-renaming `transform` processor in the collector — real work, in service of information we already have on the wire for free. Revisit only if the SSE contract proves insufficient.

### Langfuse Datasets + Scores — KEEP, but not as the runner

Langfuse starts with a real advantage: zero new infra, and evals would sit next to the traces that explain the failures. It is more capable than expected — and it is still the wrong runner *here*, for reasons specific to this repo rather than to Langfuse.

**What it genuinely gives you** (all in the free self-hosted OSS tier — datasets, scores, LLM-judge evaluators and the playground were open-sourced in June 2025, with only SCIM / audit logs / retention / project-RBAC left commercial — [pricing-self-host](https://langfuse.com/pricing-self-host), [open-sourcing announcement](https://langfuse.com/blog/2025-06-04-open-sourcing-langfuse-product)):

- Datasets with `input` / `expected_output` / `metadata`, created programmatically via `create_dataset` / `create_dataset_item`, and **automatically versioned** — every add/update/delete mints a new timestamped version, retrievable with `get_dataset(name, version=...)` ([datasets](https://langfuse.com/docs/evaluation/experiments/datasets)).
- Headless dataset runs. In SDK v4 this is `dataset.run_experiment(name=..., task=..., evaluators=[...])`, where **evaluators are plain Python functions running in your own process** and return `Evaluation(name=..., value=...)` — a deterministic exact-match assertion is three lines, no judge required ([experiments via SDK](https://langfuse.com/docs/evaluation/experiments/experiments-via-sdk)). Each item's execution automatically becomes a trace linked to a `DatasetRunItem`. No UI is involved at any point.
- Scores in four data types (`NUMERIC`, `CATEGORICAL`, `BOOLEAN`, `TEXT`), attachable to a trace, an observation, or a session, with `score_id` as an idempotency key and optional `config_id` schema validation ([scores via SDK](https://langfuse.com/docs/evaluation/evaluation-methods/scores-via-sdk)).
- A real CI story that did not exist a year ago: a `RegressionError` exception type and an official GitHub Action with `should_fail_on_regression`, dataset-version pinning, and PR comments ([experiments in CI/CD](https://langfuse.com/docs/evaluation/experiments/experiments-ci-cd), [langfuse/experiment-action](https://github.com/langfuse/experiment-action)).
- Side-by-side run comparison in the UI, and `GET /api/public/datasets/{name}/runs` programmatically.

**Why it is still not the runner for this repo — four reasons, in order of weight:**

1. **No repetitions.** *"Experiments do not contain repetitions: each dataset item appears once per experiment"* ([experiments data model](https://langfuse.com/docs/evaluation/experiments/data-model)). Our agent runs at `temperature=0.3` against local models with reasoning enabled; ADR 0003 and ADR 0007 both document failures that are *intermittent* (a turn reasoning itself out of token budget and ending with no tool call, silently). A harness that runs each case exactly once cannot measure that. promptfoo's `--repeat` can. This is the decisive one.
2. **No matrix.** A per-model sweep is N hand-written `run_experiment` calls plus your own aggregation. promptfoo's `providers:` list *is* the matrix, and the comparison view is built for it.
3. **The CI integration does not apply.** There is no `.github/` in this repo, and there cannot usefully be one: the system under test is a k3d cluster on a laptop that no hosted runner can reach. The GitHub Action — the strongest part of Langfuse's new eval story — is inert here. What remains is `run_experiment` inside pytest, at which point Langfuse is supplying a data model, not a runner.
4. **Version skew.** SDK v4's default API endpoints require **server v4**; we run **3.225.2** ([python v3→v4 upgrade path](https://langfuse.com/docs/observability/sdk/upgrade-path/python-v3-to-v4)). The v3 pattern (`with item.run(run_name=...) as span:`) works, but the CI gate and Experiment SDK do not. Adopting Langfuse-as-runner means a server upgrade, and ADR 0008 records exactly how much hand-tuning this deployment took to fit in 1.6 GiB. That tuning is not free to redo.

**What Langfuse keeps, and it is not a consolation prize:**

- It is the **only** place tool *results* exist. The SSE contract deliberately carries `tool_result` status only — *"payload stays in Langfuse"* (`server.py`). Any assertion about what a tool actually returned has to read the trace.
- It is the oracle for layer 2 (above).
- It is where a human goes when a promptfoo cell turns red. That is worth more than owning the runner.
- **Optional phase-3 nicety:** after a matrix run, map each test's `session_id` → trace → `create_score(name="ground_truth_exact", value=1|0, trace_id=...)`. The scores then sit beside the traces, Langfuse's comparison view becomes usable across model runs, and promptfoo remains the thing that decides pass/fail. This is the one place the Scores API earns its keep without becoming the runner. Do it last, not first.

### DeepEval — NO

Blunt version: its unique deterministic asset is `ToolCorrectnessMetric`, and we already have that for free.

`ToolCorrectnessMetric` compares `tools_called` against `expected_tools` with no LLM in the loop, and can be tightened with `evaluation_params=[ToolCallParams.INPUT_PARAMETERS]` to check arguments ([tool correctness](https://deepeval.com/docs/metrics-tool-correctness)). That is exactly lab 1 and lab 3. But to use it we must first extract `tools_called` from our SSE stream — at which point the comparison is a `==` and DeepEval's contribution is a threshold and a report line.

Against that:

- **The bug lands squarely on our most important case.** The metric scores 0.0, not 1.0, when both `expected_tools` and `tools_called` are empty ([issue #2024](https://github.com/confident-ai/deepeval/issues/2024)). Lab 4's evaluable behaviour is *correct absence* — `sam` must call nothing. Our single most valuable assertion is the one the library gets wrong.
- Roughly half its metric library (faithfulness, contextual precision/recall/relevancy) keys off `retrieval_context` and is dead weight — this system has no retriever.
- Its remaining value over plain pytest is judge-call caching, `-n` parallelism, and a uniform score/threshold contract. promptfoo provides all three, and we are adopting promptfoo anyway. Two eval frameworks means two places model-alias config can drift.

To be fair to it: DeepEval is genuinely local-first (no Confident AI account required, Ollama supported as judge via `deepeval set-ollama`), and if promptfoo had turned out to be a bad fit it would be the next pick. It is not needed alongside promptfoo.

### Ragas — NO

There is no retriever, no vector store, and no document corpus. Its centre of gravity — Context Precision, Context Recall, Faithfulness, Noise Sensitivity — all key off `retrieved_contexts` we will never have ([available metrics](https://docs.ragas.io/en/stable/concepts/metrics/available_metrics/)). Its non-RAG surface (`ToolCallAccuracy`, `AgentGoalAccuracy`, `TopicAdherence`, and the SQL `DataCompyScore`) is real but is a strict subset of what we get from promptfoo plus twenty lines of pandas against a 500-row JSON file. It would add an embeddings dependency for nothing.

### Testkube — NO (orchestration only, and the orchestration we would want is not in the free tier)

**Confirmed: it is an orchestrator, not an eval framework.** It runs your existing test tooling (pytest, k6, cypress, postman) as Kubernetes resources and collects results and artefacts; it scores nothing itself ([kubeshop/testkube](https://github.com/kubeshop/testkube)). `TestWorkflow` is the current CRD; `Test`, `TestSuite`, `Source`, and `Executor` are deprecated ([test workflows](https://docs.testkube.io/articles/test-workflows)). Standalone OSS *is* still supported and is not deprecated ([open source or pro](https://docs.testkube.io/articles/open-source-or-pro)).

The question that matters is whether in-cluster execution is worth it here, and the answer is no, for a reason that is almost funny:

- **The one feature that would justify it is not in the free tier.** Standalone OSS has no `matrix` parameterisation, no `parallel`, no `execute`, and no dashboard — those are Control-Plane features ([standalone agent](https://docs.testkube.io/articles/install/standalone-agent), [open source or pro](https://docs.testkube.io/articles/open-source-or-pro)). Our headline deliverable *is* a model matrix. We would write the matrix ourselves anyway, in promptfoo, and then Testkube would be running it.
- **The rest is already free.** Cron scheduling is a `CronJob`. Result history is Langfuse plus `junit.xml`. Its own docs' Helm sizing (3 nodes, 2 CPU / 8 GiB each, plus PostgreSQL, MinIO, NATS × 3) describes the Control Plane, and the standalone-only footprint is **unverified** — but any figure above zero is the wrong trade for adding a Postgres and an object store to a laptop that ADR 0008 already had to fight for 1.6 GiB of headroom.
- **In-cluster execution genuinely matters for exactly the layer-1 assertions**, and we already have it: `sandbox-airgap` runs its probe inside a claimed gVisor sandbox and its control probe in a `kubectl run` pod. That is a `Job` manifest's worth of machinery that already exists and already works.

Revisit if this ever becomes more than one cluster or more than one person. It will not.

### Tracetest and OTel-native trace assertions — NO, use the Langfuse API

**There is no OpenTelemetry-native assertion framework and no trace-based-testing standard.** The spec has nothing; the OTEP list has nothing. Everything on offer is a vendor product or a hand-rolled pytest suite — including OpenTelemetry's own, which is the precedent cited above.

What was actually checked, and why each is a no:

- **`InMemorySpanExporter`** is in-process only. Genuinely useful as tier-0 (above); structurally incapable of seeing Envoy's spans, so it cannot test lab 2.
- **The collector's `fileexporter`** (JSON-lines, OTLP-shaped) plus assertions over the dump is the best fallback, and it has one real advantage over Langfuse: it gives raw `traceId`/`spanId`/`parentSpanId` and `resource.attributes["service.name"]` rather than Langfuse's remodelled observations, so the assertion tests *our system* instead of *Langfuse's OTLP mapping*. It is `alpha` and its README warns field names may change ([fileexporter README](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/fileexporter/README.md)). Keep it in the back pocket for the day Langfuse ingestion is itself the suspect.
- **`telemetrygen`** generates load; it asserts nothing. Useful as a pipeline smoke test before the real one (ADR 0008 already used it that way), not as a test framework.
- **The collector's `testbed` module** tests the *collector's own* receivers and exporters for throughput and fidelity. Wrong layer entirely.
- **Tracetest — functionally abandoned.** It is the one purpose-built tool, and its CSS-style descendant selector (`span[service.name="a"] span[service.name="b"]`) would have expressed our property in a single line ([selectors](https://docs.tracetest.io/concepts/selectors)). But: last tagged release **v1.7.1, 2024-10-10**; last repository commit 2025-06-03 and it was a docs tweak; Kubeshop announced [end of life for Tracetest Cloud](https://tracetest.io/blog/end-of-life-announcement-for-tracetest-cloud) in October 2024 with the team "moving in new directions"; Testkube **deprecated its Tracetest executor** in the December 2025 release ([Testkube docs](https://docs.testkube.io/test-types/executor-tracetest)); and the OpenTelemetry Demo — Tracetest's flagship case study — removed it and replaced it with the hand-rolled pytest suite we are copying. The repo is not archived, but a not-archived repo with a two-year-old release is not a CI dependency. Separately, its data-store list never included Langfuse, so we would have had to add a second trace backend anyway.
- **Malabi** is archived (last push 2024-05-16) and JavaScript-only, and was in-process regardless, so it could not have seen Envoy either.
- **`pytest-opentelemetry`** instruments the *test run*, emitting spans about pytest. Commonly mistaken for an assertion library. It is not one.
- **Grafana Tempo + TraceQL** is the one maintained, vendor-supported way to express parentage as a query: structural operators `>` (child) and `>>` (descendant) shipped in Tempo 2.2, `<`/`<<` in 2.3, with union variants `&>>` returning both sides ([TraceQL](https://grafana.com/docs/tempo/latest/traceql/construct-traceql-queries/)). Our property is literally one query. But getting it means running Tempo, and ADR 0004's most expensive mistake was diagnosing against a backend that was not the one in use. Adding a trace backend to satisfy a test tool inverts the priority.

Reading Langfuse's observations and walking `parentObservationId` is forty lines and depends only on infrastructure we already run and already trust. That is the right amount of tool for this problem.

## Agent-level vs model-level evaluation

This is the question most eval tooling gets wrong, and the one this repo is unusually well-placed for.

The unit under test is **an agent turn**: tool selection → tool arguments → tool result → final answer, streamed. Most tooling assumes prompt → completion, and the standard workaround is to flatten the turn into a single string, which discards exactly the part worth testing. "Your order ORD-1001 is shipped" is a *correct-looking* answer whether the agent called `lookup_order("ORD-1001")`, called `lookup_order("ORD-1002")` and got lucky, or made it up. ADR 0007 documents the failure where the turn ends with **no tool call and no answer** — silently. A prompt/completion harness sees an empty string and reports "wrong output," which is true and useless.

**The finding that shapes the whole recommendation: we do not have to flatten.** `sse_events_for()` already emits `{"tool_use": {"id", "name", "input"}}`. A provider that consumes the stream gets tool names and tool arguments with **no OTel dependency, no instrumentation work, and no vendor's idea of what a trajectory is**. Which tools handle this shape:

| Tool | Sees tool calls? | How |
|---|---|---|
| **our SSE + a Python provider** | **yes, directly** | already on the wire |
| promptfoo `trajectory:*` | yes, indirectly | requires OTel spans with `tool.name`-style attributes — unverified against Strands |
| DeepEval | yes | you hand it `tools_called`; you still had to extract them |
| Ragas | yes | same, via `reference_tool_calls` |
| Langfuse | yes, richest | full trace including tool *results*, but after the fact and asynchronously |
| a bare OpenAI-compatible provider | **no** | flattens to prompt/completion; this is the trap |

Two consequences to design around, both read out of `server.py`:

- **`tool_use.input` is accumulated-so-far.** The comment says so explicitly. A provider that records the first `tool_use` event per `toolUseId` will assert against a truncated JSON fragment and produce a maddening intermittent failure. **Keep the last event per `toolUseId`.**
- **`tool_result` carries status only.** Asserting on what a tool returned means reading Langfuse. That seam is why both tools stay.

## The model matrix, concretely

The awkward bit: promptfoo's `providers:` list is normally the matrix axis, but **this agent's model is not chosen by the caller.** `MODEL_ID` comes from the `agent-config` ConfigMap via `envFrom`, read at import time. There are three ways to move that axis, and they are not equivalent:

| Mechanism | Reaches | Restart | Notes |
|---|---|---|---|
| (a) `kubectl patch aigatewayroute local … modelNameOverride` | Ollama backends only | **none** | *The* headline demo. Cannot reach `remote-smart` — that is a second AIGatewayRoute (`platform/gateway/openrouter.yaml`), matched by a different `x-ai-eg-model` header value. |
| (b) patch `agent-config.MODEL_ID` + `kubectl rollout restart` | all three aliases | ~30–60 s | Uniform. Zero code change. |
| (c) add an optional `model_id` to `ChatRequest` | all three aliases | none | Cleanest and parallel-safe, but a code change, and `_SESSIONS` must key on model as well as token. |

**Recommendation: start with (b).** It is uniform across `local-fast`, `local-smart`, and `remote-smart`, it needs no code change, and its cost — one rollout per alias, three times per sweep — is irrelevant against local-model inference time. Note (a) as the fast path for a local-only sweep and because it is the demo, and treat (c) as the eventual answer if the matrix is run often enough for the restarts to hurt.

Concretely, `make eval-matrix` is an outer shell loop, not a promptfoo feature:

```make
EVAL_ALIASES ?= local-fast local-smart remote-smart

eval-matrix:
	@for a in $(EVAL_ALIASES); do \
	  kubectl patch configmap agent-config --type merge -p "{\"data\":{\"MODEL_ID\":\"$$a\"}}"; \
	  kubectl rollout restart deploy/customer-agent; \
	  kubectl rollout status deploy/customer-agent --timeout=240s; \
	  npx promptfoo@latest eval -c evals/promptfooconfig.yaml \
	    --no-cache --repeat 5 -j 1 \
	    -o evals/results/$$a.json || [ $$? -eq 100 ]; \
	done
	@python3 evals/merge.py evals/results/*.json > evals/results/matrix.md
```

Four things that must be right or the matrix will mislead:

1. **`--repeat 5`, and grade on pass rate, not on a single shot.** `local-fast` is llama3.2:1b; it will not be consistent. A matrix cell should read `4/5`, not `PASS`. This is the whole reason promptfoo won over Langfuse experiments.
2. **`-j 1`.** The agent caches one `Agent` object per session and the local model serves one request at a time; concurrency here measures Ollama's queue, not the model.
3. **`temperature` is hardcoded to `0.3` in `agent.py`.** It should become an env knob (as `max_tokens` already did, for the reason ADR 0007 gives) and be set to `0` for eval runs. Even then, do not assume determinism — hence (1).
4. **A fresh `session_id` per test case.** Tool discovery happens on the first message of a session and is cached (`agent.py`'s own warning). Reusing one would silently evaluate a stale tool list — which would make the lab-4 persona cases pass for the wrong reason. promptfoo's `defaultTest.options.transformVars: '{ ...vars, sessionId: context.uuid }'` does this.

And one honesty note about `remote-smart`: it is OpenRouter's free tier, whose catalogue rotates and whose rate limits are real. Matrix cells for `remote-smart` will sometimes fail for reasons that have nothing to do with quality. The provider should surface HTTP status distinctly from a wrong answer, or the table will quietly blame the model for a 429.

## What to build first

In order. Each step is useful on its own and the first three need no cluster.

1. **`evals/ground_truth.py`** — derives every expected answer from `data/orders.json`: order lookups by ID, per-period/per-region aggregates as `Decimal`, row counts. No cluster, no model, ~50 lines. Everything else depends on it, and it makes the eval set structurally incapable of drifting from the seed data.
2. **`evals/provider.py`** — the promptfoo Python provider. Mints a Keycloak token for the named persona (the logic is already in `ask.sh`), POSTs `/chat` with a fresh `session_id`, parses the SSE stream, returns `{"output": final_text, "metadata": {"tools": [{"name", "args"}], "reasoning_chars": n, "http_status": s}}`. Keep the **last** `tool_use` per `toolUseId`.
3. **`evals/promptfooconfig.yaml`** — roughly a dozen cases, all deterministic:
   - lab 1: `lookup_order` called with exactly `ORD-1001`; answer contains the true status and tracking number.
   - lab 3: right tool among three; `initiate_return` chaining as `sam`.
   - lab 4: as `sam`, `run_python` **never** appears in `metadata.tools`, and the answer contains none of the ground-truth aggregate figures.
   - lab 5: as `ana`, `run_python` is called, and all four regional totals appear to the cent.
   - lab 5 injection: the injected instruction does not appear in any `run_python` argument.
   - a null case: an unanswerable question produces no tool call and no invented order.
4. **`make eval` / `make eval-matrix`** and the merge script that emits `matrix.md`.
5. **The lab-2 trace-shape test** (layer 2), as sketched above — plus the tier-0 `InMemorySpanExporter` unit test, which is fifteen minutes' work and needs no cluster.
6. **Fold the layer-1 demos into `make test-infra`** with real exit codes and the control-pod negative assertions kept.
7. *Only then, if it still seems worth it:* push scores back into Langfuse so the matrix is browsable next to the traces.

Steps 1–4 are the deliverable the epic actually asks for. Steps 5–7 are the ones that stop this being a demo.

## What we are choosing NOT to do, and why

- **Not making Langfuse the test runner.** No repetitions, no matrix, a CI gate that a laptop cluster cannot use, and an SDK-v4 path that would require a server upgrade of a deployment ADR 0008 hand-tuned into 1.6 GiB. It keeps the two jobs it is genuinely best at: explaining failures, and being the only place tool results and span parentage exist.
- **Not adopting DeepEval.** Its one deterministic asset duplicates something our own wire contract gives us free, and it has an open bug on empty tool lists — which is precisely lab 4's assertion.
- **Not adopting Ragas.** No retriever, no corpus, no reason.
- **Not adopting Testkube.** The matrix feature that would justify it is Control-Plane-only; everything else it offers is a `CronJob` and a `junit.xml`; and it wants a Postgres and an object store on a laptop.
- **Not adopting Tracetest or a second trace backend.** Tracetest's selector DSL is the nicest expression of this assertion anywhere, and the project has had one docs commit since October 2024, a shut-down commercial arm, a deprecated downstream in Testkube, and an ex-flagship user (the OTel Demo) that replaced it with sixty lines of pytest. Tempo's TraceQL is the maintained alternative and would cost us a second trace backend — and ADR 0004's most expensive mistake was measuring against a backend that was not the one in use.
- **Not using an LLM judge for anything with a right answer.** Every numeric claim in this system is checkable to the cent. A judge would be a second model that can regress, evaluated by nobody. Reserved for stylistic questions we are choosing not to regress at all.
- **Not building promptfoo's OTel trajectory path first.** It is the more elegant design and it may be right later. It depends on Strands' span attribute names matching promptfoo's expectations, which is unverified, and it buys information the SSE stream already carries.
- **Not wiring GitHub Actions.** No hosted runner can reach a k3d cluster on this laptop. "CI" here means a `make` target and, if we want it scheduled, a `CronJob` or a launchd timer. Pretending otherwise would produce a green badge that tests nothing.
- **Not asserting on exact span names.** Substrings and parentage only. Otherwise the lab-2 test becomes a dependency-upgrade alarm wearing a lab-2 costume.
- **Not treating a single-shot pass as a pass.** Pass rate over `--repeat`, with thresholds per alias. A 1B model that is right four times in five is a genuinely different product from one that is right once, and a boolean cannot say so.

## Consequences

- **One new dependency** (`promptfoo`, via `npx`, no install), one new directory (`evals/`), and three new `make` targets. Nothing is added to the cluster.
- **The eval set is code, not data.** Expected values are computed from `data/orders.json` at test time, so re-seeding cannot silently invalidate it.
- **`agent.py` should grow one env knob** (`MODEL_TEMPERATURE`), the same shape as the `MODEL_MAX_TOKENS` change ADR 0007 forced. Optionally a second change later (`ChatRequest.model_id`) if the matrix restarts become annoying.
- **The demo gains a number.** "Swapping the model is one `kubectl patch`" becomes "and here is what it costs" — which is the claim the workshop's thesis actually needs, and the one nobody usually makes.
- **Accepted limitation:** none of this measures streaming latency or time-to-first-token. promptfoo buffers the whole response before scoring. If SSE latency ever becomes a claim worth defending, it needs a different instrument.
