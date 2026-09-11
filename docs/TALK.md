# Every capability is a control point

*Rebuilding AWS's "Secure AI Agents on Amazon EKS" workshop on one laptop, and what the substitutions actually cost.*

This is the substitution table as an argument rather than a list. It follows the workshop's own spine — **every capability arrives as a control point in infrastructure, not as a smarter or more-trusted agent** — one lab at a time, and asks the same two questions at each stop: what does the substitution preserve, and what does it cost.

The honest answer, up front: the AWS coupling was shallow and easy. The expensive part was version pairing between open-source components, and none of it was visible from the coupling analysis this project started with.

**Anchor diagram: [`ControlPoints`](architecture/exports/structurizr-ControlPoints.png).** Keep it on screen throughout. It is the whole talk in one picture — the hexagons are the control points, one per lab, and the red box in the middle is the agent, which barely changes.

**Second diagram, for the two beats where the host boundary matters: [`Deployment`](architecture/exports/structurizr-Deployment.png).** Ollama sits outside the cluster. Two of this project's more expensive mistakes live on that line.

---

## Part 0 — The setup

AWS's workshop builds one customer-service agent across seven labs. Each lab adds exactly one production concern: model access, then tracing, then tool serving, then authorization, then code-execution sandboxing, then an autonomous coding agent. The agent's own code barely moves. What moves is what surrounds it.

The workshop's own opening argument for why any of this is necessary survives the port untouched, so it is worth stating before the substitutions. An agent is a program you can't fully predict, for three stacked reasons. **The model chooses the actions** — you ship a reasoning loop, not a call graph, and which tool runs next is decided at runtime, by a model, from the user's words. **The code is untrusted** — ask for a chart and the model writes Python; that is model output, not reviewed source, and something has to run it. **The blast radius is your cluster** — an agent pod holding the app's credentials with open egress is the whole problem in one line. So the controls go around the agent, not inside it. The workshop's presenters name five (credentials, AI gateway, MCP gateway, sandbox, egress); this rebuild counts six because the coding agent's dispatcher earns its own hexagon.

That structure is the interesting claim, and it is not obviously AWS-specific. This project tested it by removing AWS entirely and rebuilding on a single 24 GB Apple Silicon laptop. No EKS, no Bedrock, no Cognito, no DynamoDB, no cloud model required.

All seven labs run.

### How little the agent changed

`agent.py` and `server.py` were **copied verbatim** from the workshop. Not adapted — copied. They stayed that way through lab 4. Lab 5 added exactly one line, making `max_tokens` read from an environment variable, and Part 5 explains why that one line turned out to be load-bearing.

Removing AWS from the agent module took two edits:

| File | Change |
|---|---|
| `tools.py` | DynamoDB `get_item` → SQLite `SELECT`. The `@tool` signature, the docstring, and the returned dict are byte-identical, because the tool contract is the interface and the datastore is an implementation detail. |
| `requirements.txt` | dropped `boto3`. That is the entire AWS dependency in the module. |

The agent works unmodified against a local model because the workshop already routes every model call through an OpenAI-compatible base URL, and ships `api_key="not-needed"`. The workshop built the seam. This project just used it for something else.

### The coupling analysis, and why it was the wrong thing to worry about

Before building anything, the project enumerated the AWS surface and ranked it by depth. That analysis was correct and it was almost useless.

1. **DynamoDB + EKS Pod Identity** — one `get_item` and one scoped `Query`, both behind stable tool signatures.
2. **Cognito** — coupling is literally two strings and one claim name: the issuer URL, the JWKS host and path, and `jwt["cognito:groups"]`.
3. **Bedrock + SigV4** — absorbed entirely by the gateway. The most isolated dependency in the stack, by design.
4. **ECR + CodeBuild** — build and distribution only. Zero architectural weight.

Two things that were expected to be obstacles and were not. **Bedrock AgentCore is never a dependency** — it is named once as the managed alternative to agentgateway and nothing is built on it. And **no credential brokering is required**: agentgateway's `backendAuth.oauthTokenExchange` (RFC 8693), the hard part that would need an STS token vault, is used by no lab.

Every one of those predictions held. And then lab 0 was blocked for hours by something the analysis had no way to see, which is Part 1.

---

## Part 1 — Lab 0: the model gateway

**The control point: the gateway owns which model answers.**

Agents ask for an alias. The gateway rewrites it to a real model.

```
local-fast   -> llama3.2:1b
local-smart  -> qwen3:8b
```

The demo is one command:

```bash
kubectl patch aigatewayroute local --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/modelNameOverride","value":"llama3.2:1b"}]'
```

Same alias, same running agent, same image, same config. Different model now answering.

### The substitution: Bedrock → Ollama, behind the same Envoy AI Gateway

**What it preserves:** everything, and slightly more than the workshop gets. The `AIGatewayRoute` is the workshop's object with a different backend. `schema.name: OpenAI` is the load-bearing field — it declares "this backend speaks the OpenAI wire format," which is what makes Ollama, llama.cpp's `llama-server`, or vLLM all legal backends. It is the same field the workshop sets to `AWSBedrock`.

The SigV4 hop simply disappears. The workshop works hard so the agent holds no model credential; here that property is true for free, because there is no cloud credential to hold.

**What it costs:** the model. An 8B model at Q4 is not Claude Sonnet, and Part 6 is where that finally bites.

### What actually went wrong, and it was not AWS

Every request through the gateway returned:

```
No matching route found. It is likely because the model specified in your
request is not configured in the Gateway.
```

Meanwhile: `AIGatewayRoute`, `AIServiceBackend` and `Backend` all `Accepted=True`. The generated `HTTPRoute` correct, `Accepted=True`, `ResolvedRefs=True`, matching exactly on `x-ai-eg-model`. The extproc running as a native sidecar, logging `AI Gateway External Processor is ready`. Ollama answering fine when called directly. **Nothing anywhere reported an error.**

The cause: the AI Gateway controller runs as an Envoy Gateway **xDS extension server**, and Envoy Gateway has to be told to call out to it via an `extensionManager` block in its own Helm values. That post-translation hook is what injects the `ext_proc` HTTP filter. Without it the filter is absent, the model name is never extracted from the request body into `x-ai-eg-model`, the header match cannot hit, and the request falls through to a not-found handler whose error message blames the model configuration.

The file is published as `manifests/envoy-gateway-values.yaml` in the AI Gateway repo. The install docs describe the two AI Gateway Helm charts and **do not mention installing Envoy Gateway at all**, which is how it got missed.

### Two method notes from this lab that the rest of the project ran on

**Reach for the known-good reference earlier.** What found it was applying the upstream `examples/basic/basic.yaml` verbatim and watching it fail *identically*. That converted "what is wrong with my config?" — which had already consumed four wrong fixes — into "what is wrong with this cluster?", and the answer followed in minutes. A local config that fails and a reference config that fails are the same bug. A local config that fails while the reference passes is a different and much smaller search.

**Verify a diagnostic produced output before trusting what it appears to say.** An early diagnostic ran `kubectl exec … -c envoy -- curl localhost:19000/config_dump | grep -c ext_proc` and got `0`. That number was meaningless: there is no `curl` in the Envoy container, so the command emitted **zero bytes** and the grep counted nothing. Several conclusions were drawn from it before anyone checked the byte count.

This mistake recurs in Part 5 in a much more dangerous form, so it is worth planting here.

### And a host-boundary trap — show the Deployment view

With routing fixed, requests failed with `connection refused` reaching Ollama, for two independent reasons:

1. Ollama binds `127.0.0.1` by default. It must run as `OLLAMA_HOST=0.0.0.0:11434`.
2. `host.k3d.internal` is wrong on macOS. k3d injects it into CoreDNS and it looks like the obvious choice, but it resolves to the Docker bridge gateway — the Linux VM, not the Mac where Ollama listens.

| host | result |
|---|---|
| `host.docker.internal` | 200 |
| `host.k3d.internal` | connection refused |

That is a sentence in an ADR and a line in the Deployment diagram, and the line is faster.

---

## Part 2 — Lab 1: the agent, and the datastore that did not matter

**No new control point.** This lab is where the thesis gets its cleanest evidence, precisely because nothing was added.

### The substitution: DynamoDB → SQLite

**What it preserves:** the tool contract. Same `@tool` signature, same docstring — which the model reads, so it is part of the interface — same returned dict. The datastore is behind a function boundary the model never sees through.

**What it costs:** nothing this workshop teaches. DynamoDB's operational properties are real and none of them are in scope. The dataset is the workshop's own 500 orders, converted out of DynamoDB's typed JSON.

### The finding to say out loud

The model call worked first try. Tool selection worked first try — the model picked `lookup_order`, passed `ORD-1001`, and formatted the result faithfully. The single hardest thing about this lab was that qwen3 emits reasoning tokens by default.

Asked to "Reply with exactly: OK", it spent **72 completion tokens**, nearly all of it thinking, and returned empty `content` at `max_tokens: 20`. The budget was consumed before any answer was produced. The workshop's agent sets `max_tokens: 1024`; with a reasoning model that is a shared budget, not an answer budget.

Two consequences, and the second is the one that matters later:

- Do not diagnose an empty response as a broken tool call or a broken gateway. Check `usage.completion_tokens` and the `reasoning` field first.
- This is a *behavioural* difference from the workshop's Nova/Claude backends, not a configuration error. It is exactly the kind of thing a hybrid local/cloud gateway design exists to make visible.

---

## Part 3 — Lab 2: telemetry, and a retraction

**The control point: the collector.** Every workload speaks plain OTLP to it and holds no credential for the tracing backend. One key to rotate, in one place.

### What works, with zero agent code

`opentelemetry-instrument` in the Dockerfile CMD does all of it. No tracing code exists in the agent. Strands emits proper GenAI semantic-convention spans — `gen_ai.operation.name`, `gen_ai.agent.name`, `gen_ai.user.message`, `gen_ai.choice` — so the trace is richer than a bare HTTP waterfall.

One `/chat` turn is **one trace with 26 observations**, spanning the agent *and* the gateway:

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

That cross-service nesting via `traceparent` is the workshop's headline lab-2 property, reproduced in full.

### The best small finding in the project: streaming defeats naive auto-instrumentation

The first working trace had **543 spans** for one question. The ASGI middleware opens a span per SSE chunk, so ~530 of them were `POST /chat http send` carrying nothing, burying the six that mattered.

The fix was a `filter` processor in the collector, **not in the app**. 543 spans → 9.

That is the thesis arriving from an unexpected direction. Telemetry shaping is policy, and policy belongs at the control point. One collector rule fixes it for every workload that will ever stream — the same argument lab 4 makes about authorization, made about spans.

### The substitution that was not a substitution

The original decision (ADR 0004) was: **Jaeger instead of Langfuse**, on the grounds that self-hosted Langfuse v4 is six containers with official sizing guidance of 4 cores / 16 GiB, and this machine's container VM had only 11.7 GiB.

Both halves of that were wrong, and they were wrong in different ways.

**The 11.7 GiB was a misread.** This machine runs OrbStack, not Docker Desktop. `orb config show` reports `memory_mib: 12288` — a *configurable soft cap* over dynamically allocated memory, not a fixed VM ceiling. With the full cluster plus all of Langfuse running, the OrbStack helper's measured host RSS was 1.6-3.7 GiB. Nowhere near the cap. No reconfiguration was needed and none was made.

**The 16 GiB is a production sizing recommendation, not a floor.** It describes an expected ingest rate and default cache sizing, not anything structural.

Measured after actually trying: **Langfuse runs here at ~1.6 GiB idle, ~2.0 GiB under load, zero restarts.** All six containers. The gap between the assumed requirement and the measured floor was roughly a **factor of eight**.

One root cause covers most of the savings, and it generalizes past Langfuse: **ClickHouse, MinIO and Node all size their memory from host RAM, and none of them reads the cgroup limit.** Each saw ~11.7 GiB and helped itself — ClickHouse reserving a 5 GiB mark cache, Node targeting a 1.7 GiB heap — while their container limits sat unread. Every fix is the same fix: state the number absolutely rather than letting the process infer it. ClickHouse settled at **86 MiB idle against a 2 GiB limit**.

Two gotchas worth carrying:

- **"OOM" is two distinct failures.** Raising langfuse-web's container limit without raising `--max-old-space-size` left it crash-looping anyway: V8 hit its own 768 MB ceiling and died with `FATAL ERROR: Ineffective mark-compacts near heap limit` while a third of the container limit went unused. `kubectl` reports the first as `OOMKilled` and the second as plain `Error`.
- **Shrinking ClickHouse's background pool crashes it at startup**, not at load. It asserts `number_of_free_entries_in_pool_to_execute_mutation <= background_pool_size * background_merges_mutations_concurrency_ratio` and exits `BAD_ARGUMENTS` before the server ever listens.

**The one real trade:** sustained ingest throughput. 2000 telemetrygen traces at 4 workers ingested 819 in 6m40s without dropping data or restarting a pod, but did not keep up in real time. Irrelevant at demo scale — one person asking an agent questions — and the ClickHouse pool and cache settings are where to give memory back if it ever matters.

Jaeger was subsequently deleted. Langfuse is the only trace backend.

### The compounding error, which is the actual lesson

While Jaeger was the backend, this project declared an open gap ("gateway spans leave Envoy and never land"), wrote a hypothesis for it (a `TracerProvider` race in `strands-agents[otel]`), and carried both in an ADR.

The gap did not exist. It had already been fixed by an unrelated one-field change — `appProtocol: grpc` on the collector's Service, without which Envoy Gateway generates a tracing cluster with no `http2_protocol_options` and speaks gRPC over HTTP/1.1 while reporting `spans_sent` incrementing and `spans_dropped: 0`. The hypothesized race also does not exist: `strands.telemetry.tracer` calls `trace_api.get_tracer_provider()` and never constructs or sets one.

The measurements that supported the "gap" were stale queries against **a backend that had since been removed from the cluster.**

**Re-verify a known gap before writing the next theory about it, especially after changing the thing you measure with.**

A talk should say this part slowly. The substitution here — Langfuse out, then back in — was reversed not because the software changed but because the premise was finally tested. It was checkable *only* because the original decision had been written down with its reasoning exposed. That is the argument for ADRs that a process document cannot make.

---

## Part 4 — Labs 3 and 4: tools behind a gateway, and the cheapest lab in the workshop

**The control point: the agent gateway owns which tools an agent can see and call.**

### Lab 3 — no substitution at all

agentgateway is the workshop's own choice and it runs unmodified. Three objects put an MCP server behind a gateway and none of them is AWS-specific: a Service marked `appProtocol: agentgateway.dev/mcp`, an `AgentgatewayBackend` naming it as an MCP target over StreamableHTTP, and a vanilla Gateway-API `HTTPRoute`.

Two things worth showing.

**Least privilege became real, not decorative.** The orders `initContainer` and volume moved from the agent to the MCP server. `kubectl exec deploy/customer-agent -- ls /data` is now `No such file or directory`. This is exactly where the workshop's agent ServiceAccount loses its DynamoDB IAM role — the same move, with the IAM removed because there was never any IAM.

**The agent gained capabilities with no rebuild.** It stopped importing `lookup_order` and started calling `list_tools` at session start. It picked up `check_inventory` and `initiate_return` from the server's advertisement, and used `check_inventory` correctly on the first question that needed it.

The cost of routing tool calls through a gateway is that they now cross a network. Lab 4 is what that buys.

**One consequence to remember:** discovery happens on the first chat message of a session, because Strands binds auth once at transport connect. A policy change needs a *new* conversation. A reused `session_id` shows a cached tool list and looks exactly like a policy that failed to apply.

### Lab 4 — Cognito → Keycloak: two strings and one claim name

This is the shallowest substitution in the entire project and the highest-value lab in the workshop.

**What it preserves:** everything. The workshop's authorization expressions read `jwt["cognito:groups"]`. Ours read `jwt["groups"]`. Plus the issuer URL and the JWKS host and path. That is the complete Cognito coupling.

**What it costs:** one in-cluster plaintext hop where the workshop fronts Cognito over TLS on 443, on a laptop.

The result:

```
sam (support-associate)  ->  Discovered 2 MCP tools: ['lookup_order', 'initiate_return']
ana (sales-analyst)      ->  Discovered 1 MCP tools: ['lookup_order']
no token                 ->  HTTP 401 at the gateway
```

Three properties are worth landing separately, because each is a distinct idea:

**An `Allow` list that matches nothing denies everything.** Deny-by-default engages the moment any rule exists, so the workshop's step 1 (`matchExpressions: ['false']`) is a real, observable state rather than a no-op.

**`check_inventory` is not denied — it is never allowed.** There is no rule about it anywhere. That is what deny-by-default means, and it is a different sentence from "there is a deny rule."

**The two failure modes differ in a way that matters for agents specifically.** A missing or invalid token is a loud 401 at the gateway, before any tool logic runs. A *valid* token without the right makes the tool **vanish from `tools/list`**. The agent never discovers the capability, so the model does not refuse — it genuinely cannot see the thing. There is no capability to be talked into using, which is a stronger property than a refusal the model has been trained to produce.

And note the asymmetry, which is deliberate: support-associate has `initiate_return`, sales-analyst has `run_python`, and neither persona is a superset of the other.

---

## Part 5 — Lab 5: the substitution that costs something real, and the defect it exposed

**The control point: the broker.** The model picks a period and a region; the *broker* builds the scoped, parameterized query. Raw rows enter the sandbox as a **file**, never through the LLM's context. The chart comes back as bytes cached behind a short `chart_id` the model cannot dereference.

Seven separate controls, each separately verifiable, and only one of them is the runtime. That matters for what follows.

### The substitution: Kata + Firecracker → gVisor. Do not soften this.

Firecracker is a virtual machine monitor. It needs `/dev/kvm`. This node does not have it — verified, not assumed:

```
$ docker exec k3d-agentic-agent-0 ls /dev/kvm
ls: /dev/kvm: No such file or directory
```

That is not a configuration gap better flags would close. Both plausible host targets are architecturally excluded. Windows/WSL2 runs under Hyper-V, which does not expose nested non-Hyper-V hypervisors, and Microsoft states plainly that Firecracker "cannot run today." Apple Silicon has no KVM path at all. **There is no version of this repo that runs Firecracker on a consumer laptop.**

**What it preserves.** `RuntimeClass` is the seam containerd exposes for exactly this, so the swap is one field on one manifest. Everything downstream is byte-identical to the workshop: the SandboxTemplate, the WarmPool, the air-gap NetworkPolicy, `automountServiceAccountToken: false`, the single-use claim lifecycle, and the whole data-in-as-a-file discipline. Even the *verification* survives — the workshop proves isolation with `uname -r`, and so does this:

```
$ kubectl exec -n agent-sandbox <sandbox-pod> -- uname -r
4.19.0-gvisor
$ docker exec k3d-agentic-agent-0 uname -r
7.0.14-orbstack-00380-ga7e0a2dc9535
```

**What is lost, and it is not a detail.** The workshop's claim is that *"a process that escapes the container escapes into a VM, not onto the node."* Under gVisor that sentence is false.

| | Kata + Firecracker | gVisor |
|---|---|---|
| Guest kernel | real Linux, in a VM | `runsc`, a Go reimplementation in userspace |
| Enforcement | CPU virtualization extensions | syscall interception + seccomp |
| An LPE in the guest kernel gets you | ring 0 of a VM; you still face the VMM | ring 0 of nothing; you are still a `runsc` process |
| A bug in the isolation layer itself gets you | a Firecracker VMM escape (~50k LOC, jailer-confined) | a `runsc` escape onto the **host kernel** |
| Attack surface presented to hostile code | ~40 hypercalls / virtio devices | the Linux syscall ABI, reimplemented |

gVisor narrows the host syscall surface a great deal. But a sufficiently good bug in `runsc` lands the attacker on the node's kernel directly, where Firecracker would require two independent escapes.

**This build is a demonstration of the architecture of sandboxed execution. It is not a claim of equivalent assurance and should not be cited as one.** For this lab's actual threat — LLM-written pandas doing something the author did not intend — the boundary does the same job. For a hostile adversary it does not. Say both sentences.

### The finding worth more than the rebuild: the workshop's air-gap policy is fail-open

The upstream `agent-sandbox` control plane was installed unmodified, deliberately, because fidelity is the point. That decision is what surfaced this.

There are three candidate labels on a sandbox pod. Two of them are the obvious ones, and both are wrong:

- `agents.x-k8s.io/sandbox-template-ref-hash` — what the controller's generated `<template>-network-policy` selects. **Warm-pool pods never carry it**, so that policy matches zero pods and the template's `egress: []` is never enforced. The workshop documents this and ships a supplemental policy.
- `agents.x-k8s.io/warm-pool-sandbox` — what the workshop's supplemental policy selects. This label *is* present, **while the pod sits idle in the pool**, which is presumably where it was verified. The controller **removes it at claim time**, because dropping the label is how the pod is taken out of the pool.

So the workshop's air-gap policy protects the sandbox for exactly as long as the sandbox is doing nothing, and stops protecting it the instant it is handed untrusted code.

It is fail-open. It looks correct in every manifest and in every `kubectl` output. It was found by running hostile code inside a *claimed* sandbox:

```
--- stdout ---
EGRESS REACHED THE INTERNET
sa token dir exists: False
kernel: 4.19.0-gvisor
```

The fix selects `sandbox-kind: python`, set by the SandboxTemplate's `podTemplate.metadata.labels` — a non-reserved key, so it propagates to the pod and survives the claim relabel. The workshop **already depends on that survival property** for its own `kubectl -l sandbox-kind=python` verification commands. It just did not carry the insight across to the policy.

Same code, same claimed sandbox, after:

```
--- stdout ---
egress blocked: ConnectionRefusedError
sa token dir exists: False
kernel: 4.19.0-gvisor
```

### The corollary, which is now enforced in every isolation test in the repo

This project chose k3s over kind at the very start (ADR 0001) for one reason: **kindnet does not enforce NetworkPolicy**, so lab 5's `egress: []` would apply cleanly, report healthy, and enforce nothing. That was called out as the worst available failure mode for a teaching artifact, because the demo would *look* like it worked.

Then the same failure arrived anyway, from a direction that decision did not anticipate — not a CNI that ignores policy, but a correctly-enforced policy whose selector matches nothing.

> **A policy that matches no pods and a CNI that enforces no policy are indistinguishable from the outside.**
>
> **A "blocked" result with no control beside it is indistinguishable from a control that enforces nothing.**

So every isolation check in this repo now runs a **control**: the same probe, from a pod in the same namespace on the same runtime that the policy does *not* select, which must reach what the sandbox cannot.

```
=== inside a CLAIMED sandbox (not a pooled one) ===
egress blocked: ConnectionRefusedError
sa token dir exists: False
kernel: 4.19.0-gvisor

=== CONTROL: same probe from a pod the policy does NOT select ===
CONTROL connected to 1.1.1.1:443 — the policy, not the runtime, is what blocks the sandbox
```

Without that second block, the first block is a screenshot of nothing.

This connects straight back to Part 1's zero-byte `curl`. Both are the same error: **a negative result treated as evidence without first establishing that the instrument works.**

### A silent failure that has nothing to do with security

`run_python`'s `code` argument is an entire Python program — the largest tool argument in the repo by an order of magnitude. qwen3 spends its budget on reasoning *before* it emits the tool call, so the reasoning block and the generated program compete for the same allowance.

At the repo's previous fixed `max_tokens: 2048`, twice in a row:

```
--- attempt 1
reasoning chars=2313 answer chars=0 tools=None
--- attempt 2
reasoning chars=1496 answer chars=0 tools=None
```

The log shows the model reasoning correctly and completely. It picks `run_python`, plans the pandas, plans the matplotlib, and ends with *"Let me put this into the function call with the correct parameters."* Then the turn ends. No `tool_use` event, no answer, no error. The user sees nothing.

At 6144:

```
reasoning chars=2195 answer chars=280 tools={'run_python'}
reasoning chars=4042 answer chars=420 tools={'run_python'}
```

The 4042-character reasoning block alone exceeds what 2048 could have held together with a program.

The generalizable version: **a token budget adequate for a tool catalogue is not adequate for the next tool added to it.** Adding a tool whose arguments are large is a change to the model configuration, whether or not anyone treats it as one. And the failure is silent by construction — budget exhaustion mid-tool-call produces an empty turn, not an exception, so anything watching for tool errors sees nothing. Watch for turns that produce reasoning and no `tool_use`.

This is a local-model constraint, not a workshop one, and it is precisely why the workshop's own code never had to expose the knob. That is what running the thing on different hardware buys you.

---

## Part 6 — Labs 6-7: the coding agent, and the thesis stated as an experiment

The workshop frames labs 5 and 6-7 as **the two postures an agent can take toward a sandbox**, and the pairing is worth a beat before the mechanics. In lab 5 the agent stays *outside*: an ordinary pod that reasons and calls tools, reaching the sandbox as a tool — `run_python` through the MCP gateway — while the untrusted code goes in alone, air-gapped, credential-free, destroyed after one run. Here the posture inverts and **the agent is the payload**: Claude Code itself runs inside the sandbox, holding no human credential, with egress to exactly two services, and its model-written changes never touch the node. Same sandbox control point, pointed in the opposite direction.

**The control point: the dispatcher.** It mints a per-run git token and revokes it in a `finally`. It claims a sandbox. And it holds the push credential, so the model never does.

```
$ make coding-issue TITLE="Add a /version endpoint" BODY="Return {\"version\": \"1.0.0\"}. Add a test."
filed issue #3 -> labelled 'agent' -> webhook fired

$ make coding-show N=3
  [coding-agent-bot] 🤖 Working on this in an isolated sandbox…
  [coding-agent-bot] ✅ Opened PR #4: .../pulls/4
  #4  Fix issue #3    open <- agent/issue-3   ### Tests passed | 2 passed
```

The agent commits. The **wrapper** pushes and opens the PR. `task.md` tells the agent not to push, but that instruction is a courtesy, not a control — `GITEA_TOKEN` and the `git push` line live in `run.sh`, which runs after the agent has exited. The agent could not push if it tried.

**The PR is the human-in-the-loop boundary, and the agent's job ends there.**

### The substitution: Claude on Bedrock → Claude Code on a free hosted model, through the same gateway

This machine has no Anthropic credential. No `ANTHROPIC_API_KEY`, no `ANTHROPIC_AUTH_TOKEN`, no `~/.claude/.credentials.json`. Reproducing the lab therefore required answering a question the workshop never has to ask: **what exactly is the agent binary, and how much of the lab depends on it being that particular one?**

Two decisions, and the second is what makes the first cheap.

**1. The agent is a swappable command.** `run.sh` invokes one line: `bash /opt/agents/$CODING_AGENT.sh`, selected by an environment variable on the dispatcher Deployment. Each script in the sandbox image's `/opt/agents/` is a complete coding agent with a fixed contract: `task.md` in, a commit on the current branch out, no push credential in its hands. Two ship — `claude` (Claude Code, unpatched) and `minimal` (~150 lines of tool-calling loop).

**2. The compatibility layer is the AI gateway, not a proxy beside it.** Envoy AI Gateway v1.0 accepts the Anthropic Messages wire format on `/anthropic/v1/messages` and translates it to whatever the backend speaks. That is documented for Bedrock; it was *not* obvious it works against an arbitrary self-hosted OpenAI backend. It does, and it was verified before anything was built on it — text, streaming SSE, and `tool_use`.

That matters beyond tidiness. A translating sidecar (claudish and similar) is a component that has to hold the model credential, and the gateway already holds it. Keeping translation in the gateway keeps the key at the cluster edge, which is the property lab 0 exists to demonstrate. **The lab-0 control point does real work here for the first time.**

**What the substitution preserves:** the agent binary. `claude -p`, unpatched, is what runs. Claude Code does not need an Anthropic account when `ANTHROPIC_BASE_URL` points elsewhere and `ANTHROPIC_AUTH_TOKEN` is set to any placeholder — it reports `apiKeySource: ANTHROPIC_API_KEY` and never attempts a login. This was the assumption most worth testing and it turned out false in the helpful direction.

**What it costs:** a weaker, rate-limited model. Rate limits are left to fail visibly rather than papered over with retries.

### The blocker was a 32 KiB buffer, and both error messages lied

Claude Code's first request carries its system prompt and ~20 tool schemas, and the AI Gateway's ext_proc filter must buffer the whole body to translate it. Envoy Gateway's default `connection.bufferLimit` is 32 KiB. From inside the sandbox:

```
[claude-code:unrecognized_model] {"model":"local-smart","query_source":"sdk"}
Request too large (max 32MB). Accumulated images and attachments in the
conversation pushed the request over the limit.
```

Neither sentence is true. There are no images and no attachments. The limit is 32 KiB, not 32 MB. The model is fine. Claude Code is rendering a bare HTTP 413 through its own error vocabulary, and the more prominent line blames the model.

Located by ignoring both messages and measuring the gateway directly with synthetic bodies: 8 KB → 200, 32 KB → 413.

### The capability wall, which is the honest result

With the plumbing correct, qwen3:8b still failed. Asked to create a file, it emitted a rambling essay about filesystem permissions and a malformed `Write "/banana.txt.tmp…"`. The same model drives the `minimal` agent's three-tool loop correctly.

That is a capability wall, not a wiring problem, and it is what justifies the whole swappable-agent structure. `MODEL_MAIN=remote-smart` moves the coding agent from an 8B model on the laptop to a 120B model in someone else's datacenter, and that move is **an edit to the alias table**: one backend, two aliases, no agent code, no image rebuild, no dispatcher change.

### The thesis, stated as an experiment rather than an assertion

Run `minimal` with `MODEL_MAIN=local-smart` and the entire lab holds with no account anywhere on the machine. The per-run token is still minted and revoked. The egress is still locked to two services. The sandbox still has no service-account token. The wrapper still holds the push credential. The PR is still where a human enters.

**Every one of the four limits is a property of the boundary. None of them is a property of which binary sits inside it.**

That is the workshop's claim, and this is the closest thing to a controlled test of it that the project produced — because the variable that was supposed to matter most, the agent itself, was swapped, and nothing about the security posture moved.

### A bad PR is a working system

The `minimal` agent's first end-to-end run wrote `app/repo/app.py` instead of `app.py`: the model answered with an absolute path and `safe_path` did `REPO / rel.lstrip("/")`. The run still pushed, still ran pytest, still opened the PR, and the PR body carried the collection error. Nobody had to go looking.

The bug is fixed. The episode is the argument for the boundary: **the agent produced wrong output and the worst consequence was a pull request a human declined to merge.**

### Two facts about k3s the workshop's manifests cannot carry

**Egress policy is evaluated after DNAT.** kube-router sees the destination *pod* IP and the *pod* port, so the workshop's service-CIDR `ipBlock` escape hatch is unnecessary here — and dropping it is a **tightening**, since on the workshop's CNI that `ipBlock` permits any ClusterIP on the listed port.

But the port must then be the *target* port. The AI gateway's Service is `80 → targetPort 10080`, and a rule allowing only 80 silently blocked the model path while Gitea (`3000 → 3000`) worked fine.

**An allow rule that matches nothing is indistinguishable from a deny.** That is Part 5's lesson arriving from the positive direction, and it is strictly harder: an allowlist can fail by being too *narrow*, and that failure is invisible unless the cases that must **succeed** are run too. `make coding-egress-check` runs all six — two that must reach, four that must not, plus the inverted control.

---

## Part 7 — What it actually cost

### The recurring cost was version pairing, and the coupling analysis could not see it

The AWS coupling was enumerable and shallow, and every prediction about it held. Cognito really was two strings and one claim name.

Here is what the enumeration missed:

| Pairing | Symptom | Real cause |
|---|---|---|
| Envoy Gateway installed without AI Gateway's `extensionManager` values | `No matching route found`, every CRD `Accepted=True` | the AI Gateway controller is an xDS extension server; without the hook the `ext_proc` filter is never injected |
| Envoy Gateway **v1.5.6** + AI Gateway **v1.0.0** | `BackendTLSPolicy` applied cleanly and was silently ignored; the gateway dialled `openrouter.ai:443` in cleartext and got `400 The plain HTTP request was sent to HTTPS port` | EG v1.5.6 watches `BackendTLSPolicy` at `v1alpha3`; the cluster served `v1` only. **v1.8.1 is AI Gateway v1.0.0's documented minimum** — this was never a supported pairing |
| Envoy Gateway v1.8.x + Gateway API CRDs < 1.5.0 | controller crashloops on `no matches for kind "ListenerSet"` | EG v1.8.x watches `ListenerSet` at `gateway.networking.k8s.io/v1`, which only exists in the 1.5.0 bundle |
| agentgateway control plane installed before its CRD chart | crashloop on `Unauthorized` | ordering |
| A Gateway named after its own Helm release | immutable-selector error retrying forever **while the Gateway reports `Programmed=True`** | the chart owns a Deployment of that name; the Gateway controller creates a data-plane Deployment named after the Gateway |
| `k8s-agent-sandbox` SDK vs the agent-sandbox control plane | — | they share a CRD contract and are pinned together at v0.5.0. They move together or not at all |

**The risk in porting a cloud workshop is not the cloud coupling you can enumerate. It is the install-order and version-pairing knowledge the vendor docs assume.** Budget for it.

The `BackendTLSPolicy` row deserves its own beat, because the diagnosis was wrong first. The cleartext hop was blamed on k3s's Traefik owning the Gateway API CRDs, and worked around with an in-cluster nginx doing TLS origination. Removing Traefik did not fix it. The tell was an **empty `.status.ancestors`** — a Gateway API policy that no controller has claimed. **A resource that applies successfully and is then silently ignored is worse than one that fails, because `kubectl apply` reports success.**

Traefik was removed anyway, on its own merits: zero `Ingress` objects, no Traefik `GatewayClass`, three pods, and a second set of Gateway API CRDs in a cluster whose entire point is Gateway-API-based routing. All 28 workload pods stayed Running through the removal.

### Three diagnoses blamed the wrong component, and each time it was the one that had caused trouble before

1. Missing gateway spans → blamed Envoy. Actually the *collector Service* was missing `appProtocol: grpc`.
2. A cleartext TLS hop → blamed Traefik. Actually an apiVersion mismatch.
3. A "trace-joining gap" carried in an ADR → actually already fixed by (1), and measured against a backend that had been deleted.

The habit those produced: **check what the API server actually serves before blaming a component for ignoring a resource.**

```bash
kubectl get crd <name> -o jsonpath='{.spec.versions[*].name}'
```

### One prediction that was over-feared

The plan warned that small-model tool calling would be the binding risk, quoting ~46.75% BFCL v4 multi-turn for Qwen3-8B against ~74% for frontier models. In practice single-tool selection was reliable across labs 1 through 5. It bit exactly once, in labs 6-7, where Claude Code's tool protocol is genuinely beyond an 8B model — and the architecture already had the answer, because swapping the model is an edit to the alias table.

---

## The substitution table

Now it is a summary rather than an argument.

| Layer | Workshop | Here | Preserves | Costs |
|---|---|---|---|---|
| Cluster | EKS | **k3d / k3s** | NetworkPolicy actually enforced (kube-router) | nothing this teaches. **Not kind** — kindnet ignores NetworkPolicy, and labs 5-7 would look like they work |
| Model | Bedrock (+ SigV4 via Pod Identity) | **Ollama on the host** | the whole hop. `schema.name: OpenAI` makes any OpenAI-wire engine legal. The SigV4 hop disappears and the no-credential property is free | model capability. An 8B model cannot drive Claude Code |
| Model gateway | Envoy AI Gateway | **same** | — | the `extensionManager` install-order knowledge |
| Orders store | DynamoDB | **SQLite** | `@tool` signature, docstring, returned dict — byte-identical | nothing in scope. DynamoDB's operational properties are not what this teaches |
| Tracing | Langfuse | **same**, hand-tuned to ~1.6 GiB | all six containers, the LLM-specific UI, token cost attribution, prompt management | sustained ingest throughput (819 of 2000 traces in 6m40s, no data loss). Irrelevant at demo scale |
| Tool gateway | agentgateway | **same** | — | do not name the Gateway after its Helm release |
| Identity | Amazon Cognito | **Keycloak** | everything. Coupling was the issuer, the JWKS host/path, and `cognito:groups` → `groups` | one in-cluster plaintext JWKS hop |
| Sandbox control plane | kubernetes-sigs/agent-sandbox | **same, unmodified, v0.5.0 pinned** | the claim/relabel lifecycle, warm pooling, the SDK — all of it. Installed clean on arm64/k3s first try | SDK and controller share a CRD contract and move together |
| Sandbox runtime | Kata + **Firecracker** | **gVisor via RuntimeClass** | one field on one manifest. Template, warm pool, air-gap policy, `automountServiceAccountToken: false`, single-use lifecycle, data-in-as-a-file — and the `uname -r` verification | **the assurance level.** "Escapes into a VM, not onto the node" becomes false. One escape instead of two |
| Coding agent | Claude Code → Claude on Bedrock | **Claude Code → OpenRouter, through the same gateway** | the binary, unpatched. The gateway is the Anthropic-compatibility layer, so no proxy holds the key | a weaker, rate-limited model |
| Git server | Gitea | **same**, plain Deployment | everything the lab teaches | no HTTPS front door; reached by port-forward. Nothing depends on the CloudFront/ALB hop |
| Images | ECR + CodeBuild | **local build + `k3d image import`** | — | rebuilt images are invisible to a warm pool until it recycles (`imagePullPolicy: Never`) |

**Nothing is "not reproducible." One lab is degraded on exactly one axis, and that axis is nameable.**

---

## Closing

Six control points. One agent that barely changed.

Every lab in this workshop adds a capability by adding infrastructure between the agent and something it wants, and the substitutions confirm it from an unexpected angle: **the things that were easy to swap were the AWS services, and the things that hurt were the seams between the open-source components that replaced them.** The architecture ported cleanly. The wiring did not.

Two results the rebuild produced that the original workshop could not:

- **The workshop's own air-gap NetworkPolicy is fail-open.** It protects a sandbox precisely as long as the sandbox is doing nothing. Found by running hostile code in a claimed sandbox, not by reading YAML.
- **A production sizing recommendation was read as a requirement**, and the gap was a factor of eight. It was checkable only because the wrong decision had been written down with its reasoning exposed.

The rule that came out of both, and the one worth taking away:

> **A "blocked" result with no control beside it is indistinguishable from a control that enforces nothing.**

Run the positive case. Verify the instrument produced output. Then believe the result.

---

## Appendix — where to look in the repo

| For | Read |
|---|---|
| Getting it running | [RUNBOOK.md](RUNBOOK.md) |
| The diagrams and how they are generated | [architecture/README.md](architecture/README.md), `architecture/workspace.dsl` |
| The best single piece of writing in the repo | `platform/sandbox/sandbox-airgap-networkpolicy.yaml` — the header, all 43 lines of it |
| Cluster choice | [ADR 0001](adr/0001-k3s-not-kind.md) |
| The lab-0 blocker, in full | [ADR 0002](adr/0002-ai-gateway-extproc-not-wired.md) |
| Reasoning tokens | [ADR 0003](adr/0003-reasoning-tokens.md) |
| Observability, and a retracted diagnosis | [ADR 0004](adr/0004-observability-backend-and-gateway-spans.md) |
| What gVisor gives up | [ADR 0005](adr/0005-gvisor-not-kata-firecracker.md) |
| The air-gap defect | [ADR 0006](adr/0006-upstream-agent-sandbox-control-plane.md) |
| The silent token-budget failure | [ADR 0007](adr/0007-tool-call-token-budget.md) |
| The Langfuse retraction, with measurements | [ADR 0008](adr/0008-langfuse-fits-after-all.md) |
| The swappable coding agent | [ADR 0009](adr/0009-coding-agent-is-a-swappable-command.md) |
| Traefik, and the apiVersion gap | [ADR 0010](adr/0010-no-traefik-and-the-backendtlspolicy-version-gap.md) |
| The seven controls of lab 5 | `modules/900-sandbox/README.md` |
| The four limits of labs 6-7 | `modules/1000-coding-agent/README.md` |
| The full feasibility evaluation, prediction vs measurement | the companion wiki's `homelab-agentic-platform-plan.md` |
