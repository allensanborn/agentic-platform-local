# 900 — Sandboxed code execution (gVisor)

Give the agent a **`run_python`** tool that executes untrusted, model-generated Python inside
a **per-execution sandbox**, vended by the upstream `agent-sandbox` control plane on this
repo's `gvisor` RuntimeClass.

Local port of the workshop's `900-sandboxed-code-exec`. Two substitutions, both forced, both
documented: **gVisor instead of Kata + Firecracker** ([ADR 0005](../../docs/adr/0005-gvisor-not-kata-firecracker.md))
and **SQLite instead of DynamoDB**. The control plane is the same upstream software the
workshop uses, installed unmodified ([ADR 0006](../../docs/adr/0006-upstream-agent-sandbox-control-plane.md)).

## Why

For analytical questions over many orders ("Q1 sales by region"), the agent should *write
code*, not ask for raw rows. Running that code is untrusted, so it runs kernel-isolated and
air-gapped — no network, no credentials.

## Architecture

```
UI (sales-analyst) -> agent -> agentgateway [authz: run_python -> sales-analyst]
  -> code-executor MCP broker (scoped parameterized SQL; holds SandboxClaim RBAC)
       -> sandbox-router -> gVisor sandbox (air-gapped): pandas over /app/orders.json
```

## The seven things this lab is actually teaching

Each one is a separate control, and each is separately verifiable.

1. **The broker builds the query, the model picks the parameters.** `query.py` takes a period
   and optional filters, validates every one against a regex or an allow-list, and binds them
   as `?` placeholders. The model never writes SQL, never names a column, never supplies an
   expression. Two independent barriers, so bypassing either alone is not enough —
   `test_query.py` pins both.
2. **Raw rows enter the sandbox as a file, never through the LLM's context.** The broker
   fetches 139 rows for `2026-Q1` and writes them to `/app/orders.json` over the router. The
   model sees the row count, not the rows.
3. **Generated code enters as a file too**, and runs air-gapped with no credentials.
4. **The chart comes back as bytes the broker caches behind a short `chart_id`.** The model
   sees only the id. `@mcp.custom_route("/chart/{id}")` serves the PNG and deliberately skips
   MCP authorization — the id is the capability.
5. **Single-use.** Claim, run, destroy, pool replaces. `make sandbox-lifecycle` shows it.
6. **`egress: []` with `policyTypes: [Ingress, Egress]` means "no destination permitted",**
   not "no rules configured".
7. **`automountServiceAccountToken: false`** — the sandbox holds no Kubernetes credential.
   The broker holds the SandboxClaim RBAC; the thing running hostile code holds nothing.

## Run it

```bash
make sandbox          # gvisor + control plane + images + broker + policy
make sandbox-forward  # in another shell: the four port-forwards the probes need
make sandbox-test     # broker over MCP, then the persona split through the gateway
make sandbox-airgap   # hostile code in a CLAIMED sandbox, plus the control
make sandbox-pool     # template, warm pool, live claims, labels, policies
make sandbox-unit     # broker unit tests, no cluster needed
```

End to end through the model, as a persona:

```bash
make sandbox-ask USER_NAME=ana Q="What were total 2026-Q1 sales aggregated by region?"
make sandbox-ask USER_NAME=sam Q="What were total 2026-Q1 sales aggregated by region?"
```

## `probe.py` is the control, and that is the point

The local model is a 8B parameter model doing tool calls. When something does not work, the
first question is always *whose fault* — and a probe that speaks MCP directly, with no model
in the path, answers it in one command. Every claim in the ADRs was made against the probe
first and the agent second. A working broker with a flaky model is a legitimate result; a
broken broker hidden behind a flaky model is not, and this is what tells them apart.

The same discipline applies to the air-gap. `make sandbox-airgap` runs the probe from a pod
the policy does **not** select immediately after running it from one the policy does. A
"blocked" with no control beside it proves nothing — see ADR 0006 for how that exact gap hid
a real hole in the workshop's own manifest.

## Known gaps

**The chat UI does not render the chart.** The broker's half works: the sandbox writes
`/app/chart.png`, the broker caches the bytes, mints a `chart_id`, and serves it on
`GET /chart/{id}` with `Content-Type: image/png` — `probe.py --chart` fetches it and verifies
the PNG magic. What is missing is the last hop: `server.py`'s SSE contract (shared with
`modules/300-ui/chat-ui/app.py`) has no event type for an image, so nothing carries the id to
the browser. The model, seeing only an opaque id and no way to display it, writes a markdown
image tag pointing at an invented URL. Closing this means adding an event to a wire contract
that labs 1 and 2 also depend on, which is a bigger change than lab 5 should make on its own.
The *security* property the lab teaches — bytes never traverse the LLM — is intact and
verified; only the presentation is absent.

**Charts need `MODEL_MAX_TOKENS` at 6144.** At the repo's previous 2048 the model reasoned
itself out of budget mid-tool-call and produced a silent empty turn. See
[ADR 0007](../../docs/adr/0007-tool-call-token-budget.md). Text aggregations worked at 2048.

**A claimed sandbox reports `READY False` / `DependenciesNotReady`** while it is running, and
the pod shows `0/1`. This is the controller pulling the pod out of the warm pool's readiness
accounting, not a fault — the run completes normally. Do not read it as an error.

## Authz

`policies/run-python-authz.yaml` gates `run_python` to the sales-analyst persona. One string
differs from the workshop: `jwt["groups"]` instead of `jwt["cognito:groups"]`, the same
substitution lab 4 made. It relies on lab 4's gateway-wide `mcp-authn` policy for the JWT
itself, so **lab 4 must be applied first** or there is no `jwt` for the rule to read.

Note the asymmetry with lab 4: support-associate has `initiate_return`, sales-analyst has
`run_python`, and neither persona is a superset of the other.
