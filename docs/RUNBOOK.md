# Run-book — clone to working demo

For someone who has never seen this repo. It assumes a macOS or Linux host with a container engine and no prior state.

Read [TALK.md](TALK.md) for *why* any of this is shaped the way it is. This file is only *how*.

Two warnings before anything else, because both cost real time here:

1. **`make up-all` does not bring up labs 3 and 4.** The MCP server, the agentgateway control plane, and the authorization policies have no Makefile target at all. They were installed by hand and never scripted. [Labs 3 and 4 — the manual part](#labs-3-and-4--the-manual-part) is the gap and what to do about it. Without it the agent has no tools, because since lab 3 it discovers them over MCP instead of importing them.
2. **Verify that a diagnostic produced output before believing what it appears to say.** This repo's ADRs contain three separate wrong conclusions drawn from commands that emitted zero bytes ([ADR 0002](adr/0002-ai-gateway-extproc-not-wired.md), [ADR 0004](adr/0004-observability-backend-and-gateway-spans.md)). `out=$(cmd 2>&1); echo "${#out}"` before you reason about the content.

---

## Prerequisites

| Thing | Why | Note |
|---|---|---|
| Docker engine | k3d nodes are containers; images are built and side-loaded locally | OrbStack is what this was built on. Docker Desktop should work, but `host.docker.internal` behaviour is the one thing to re-verify — see [ADR 0002](adr/0002-ai-gateway-extproc-not-wired.md) |
| `k3d` | the cluster. **Not kind** — kindnet silently ignores NetworkPolicy and labs 5-7 would look like they work while enforcing nothing ([ADR 0001](adr/0001-k3s-not-kind.md)) | `brew install k3d` |
| `kubectl` | everything | |
| `helm` | Envoy Gateway, Envoy AI Gateway, agentgateway all ship as charts | |
| `ollama` | the local models, running **on the host**, not in the cluster, because that is where the GPU is | `brew install ollama` |
| `uv` + Python 3.12 | the agent/broker virtualenvs and the unit tests | |
| `curl` | the gVisor and agent-sandbox install scripts fetch binaries and manifests | |
| Disk + RAM | ~8 GB free disk for models and images. The full stack is ~28 workload pods; Langfuse alone is six containers at ~1.6 GiB idle ([ADR 0008](adr/0008-langfuse-fits-after-all.md)) | |

Optional, only for the Claude Code path in labs 6-7: an [OpenRouter](https://openrouter.ai/keys) API key. Models with a `:free` suffix cost nothing.

Not required, and deliberately so: no AWS account, no Anthropic account, no cloud model.

---

## Cold start

Order matters, and `up-all`'s own comment block says why. Reproduced here because it is the part most likely to be skipped:

- Gateway API v1.5.0 CRDs must exist **before** Envoy Gateway v1.8.x, which watches `ListenerSet` at `gateway.networking.k8s.io/v1`. Without them the controller crashloops on `no matches for kind "ListenerSet"`.
- CRD charts before their control planes. agentgateway crashloops on `Unauthorized` in the other order.
- gVisor before any sandbox pod schedules. `make gvisor` restarts the k3d agent node.
- Gitea before `coding-deploy`; the dispatcher mounts the `coding-agent-creds` Secret that `platform/gitea/provision.sh` creates.

```bash
git clone git@github.com:allensanborn/agentic-platform-local.git
cd agentic-platform-local
make up-all
```

`up-all` = `cluster gvisor sandbox-platform observability identity gitea images deploy sandbox-images sandbox-deploy coding-images coding-platform coding-deploy`.

Expect **20-40 minutes** on a first run, most of it pulling images. Two stages look hung and are not:

- **`make gvisor`** downloads `runsc` + the containerd shim, `docker restart`s the k3d agent node, then blocks in a `until kubectl get node … Ready` loop. The node going NotReady mid-target is expected.
- **`make observability`** waits on `deploy/langfuse-web` with a **600-second** timeout. Langfuse is web + worker + Postgres + ClickHouse + Redis + MinIO, and ClickHouse's first start initializes its data directory. Several minutes of no output is normal. If `langfuse-web` restarts with plain `Error` rather than `OOMKilled`, that is V8 hitting `--max-old-space-size`, not the container limit — the two are a pair and `kubectl` distinguishes them ([ADR 0008](adr/0008-langfuse-fits-after-all.md)).

`up-all` prints the remaining manual steps when it finishes. They are manual on purpose — three of them involve a multi-GB download or a credential, and one needs a second shell.

### The manual steps `up-all` deliberately leaves out

**1. Pull the models.** `make model` pulls only `$(MODEL_ID)`, which defaults to `qwen3:8b` (~5 GB). Lab 0's alias table also maps `local-fast` to `llama3.2:1b`, and nothing pulls that:

```bash
make model                 # qwen3:8b        -> alias local-smart
ollama pull llama3.2:1b    # ~1.3 GB         -> alias local-fast
```

Ten to twenty minutes on a normal connection, and it is the single longest step in the whole bring-up. `ollama list` to confirm both are present.

**2. Serve the model on all interfaces, in its own shell.** Ollama binds `127.0.0.1` by default, which the cluster cannot reach:

```bash
make serve-model     # OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

This blocks. Leave it running. If `ollama serve` is already running as a login agent on `127.0.0.1`, stop it first, or the bind fails and the cluster keeps getting `connection refused`.

**3. The model key, only if you want the hosted path.** Skipping this is fine: labs 0-5 do not need it, and labs 6-7 run fully on the local model with `CODING_AGENT=minimal`.

```bash
printf '%s' 'sk-or-v1-...' > .secrets/openrouter.key   # gitignored
make model-key        # -> Secret model-access/openrouter, then default/openrouter-apikey
make model-remote     # adds the OpenRouter backend + remote-smart / remote-fast aliases
make model-remote-test
```

The key is never passed on a command line and never written to a tracked file. `.secrets/` and `*.key` are in `.gitignore`.

> **`make model-remote` is broken as written.** Its first line is
> `kubectl rollout status -n model-access deploy/openrouter (direct TLS) --timeout=180s`
> — the parenthetical is a leftover from removing the nginx TLS-origination sidecar, and there is no `deploy/openrouter` in `model-access` any more. Until that line is deleted, apply the manifest by hand: `kubectl apply -f platform/gateway/openrouter.yaml`.

**4. The UI, in its own shell.**

```bash
make ui              # port-forward svc/chat-ui 8000 -> http://127.0.0.1:8000
```

---

## Labs 3 and 4 — the manual part

`modules/500-mcp/` (lab 3) and `modules/700-authz/` (lab 4) ship complete, commented manifests and **no automation whatsoever**:

- `make images` builds `customer-agent:local` and `chat-ui:local` only. `mcp-server:local` is never built, and `modules/500-mcp/mcp-server/k8s.yaml` sets `imagePullPolicy: Never`, so the Deployment will sit in `ErrImageNeverPull`.
- `make deploy` applies the agent and the UI only. Neither `modules/500-mcp/mcp-server/k8s.yaml` nor `modules/700-authz/policies/step3-differentiate.yaml` is applied by any target.
- Nothing anywhere in the repo or its git history installs the **agentgateway control plane**. The `agentgateway` GatewayClass and the `mcp-gateway` Gateway are declared in `modules/500-mcp/mcp-server/k8s.yaml`, but the controller that reconciles them has to come from its Helm charts, and those commands were never captured.

This matters more than a missing convenience target, because the agent's ConfigMap points `MCP_SERVER_URLS` at `mcp-gateway.agentgateway-system.svc.cluster.local`. A cluster built from `up-all` alone gives you an agent that starts, connects to nothing, and discovers zero tools.

Until the targets exist, the sequence is:

```bash
# 1. the agentgateway control plane — CRD chart FIRST, then the controller.
#    Installing them in the other order crashloops the controller on Unauthorized.
#    (Chart coordinates and version are not recorded in this repo; take them from
#    agentgateway's own install docs, into namespace agentgateway-system.)

# 2. the MCP server image, which `make images` does not build
docker build -q -t mcp-server:local modules/500-mcp/mcp-server
k3d image import mcp-server:local -c agentic

# 3. lab 3 — the MCP server, the Gateway, the AgentgatewayBackend, the HTTPRoute
kubectl apply -f modules/500-mcp/mcp-server/k8s.yaml
kubectl rollout status deploy/mcp-server --timeout=180s

# 4. lab 4 — JWT authentication on the Gateway + per-tool authorization.
#    `make identity` (Keycloak + the anycompany realm) must already have run;
#    up-all includes it.
kubectl apply -f modules/700-authz/policies/step3-differentiate.yaml

# 5. lab 5's run_python policy depends on lab 4's gateway-wide mcp-authn policy
#    for the JWT it reads. `make sandbox-deploy` applies it, but it is inert
#    without step 4.
kubectl rollout restart deploy/customer-agent
```

Do **not** name that Gateway `agentgateway`. The Helm chart owns a Deployment of that name in the same namespace, the Gateway controller creates a data-plane Deployment named after the Gateway, and the collision is an immutable-selector error that retries forever while the Gateway still reports `Programmed=True`. The manifest already names it `mcp-gateway` and says so in a comment.

---

## Verifying each lab

Run the port-forwards first. `make sandbox-forward` opens all four in one blocking shell:

```
broker :8090   mcp-gateway :8081   keycloak :8085   agent :8082
```

(The banner calls `:8081` "gateway"; it is the *agent* gateway, not the AI gateway. `make gw-forward` is the AI gateway, on `:8080`.)

### Lab 0 — the model gateway owns which model answers

```bash
make gw-forward       # separate shell, AI gateway on :8080
make agent-via-gateway
```

The payoff is the alias table, and it is worth doing live:

```bash
kubectl patch aigatewayroute local --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/modelNameOverride","value":"llama3.2:1b"}]'
```

Same alias, same agent pod, same image, different model answering.

If every request returns `No matching route found. It is likely because the model specified in your request is not configured in the Gateway.` while every CRD reports `Accepted=True`, the cause is almost certainly the `extensionManager` block missing from Envoy Gateway's Helm values. `make cluster` fetches the correct values file from the AI Gateway repo; read [ADR 0002](adr/0002-ai-gateway-extproc-not-wired.md) before debugging anything else. The error message blames the model configuration and the model configuration is fine.

### Lab 1 — the agent, in and out of cluster

```bash
make venv && make agent          # one-shot CLI against the model directly
make ui                          # in-cluster, http://127.0.0.1:8000
```

An empty answer is not necessarily a broken tool call. qwen3 emits reasoning tokens by default; check `usage.completion_tokens` and the `reasoning` field before diagnosing anything else ([ADR 0003](adr/0003-reasoning-tokens.md)).

### Lab 2 — one trace across two services

Port-forward `langfuse-web` in the `langfuse` namespace, ask the UI one question, and look for a **single trace with 26 observations** containing both the agent's spans and Envoy's:

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

Two traces instead of one means the gateway is not continuing the agent's `traceparent`. The historical cause was the collector's Service missing `appProtocol: grpc`, which made Envoy speak gRPC over HTTP/1.1 while reporting `spans_sent` incrementing and `spans_dropped: 0` ([ADR 0004](adr/0004-observability-backend-and-gateway-spans.md)).

### Lab 3 — tools discovered at runtime

Start a **new** session and watch the agent log for `Discovered N MCP tools`. Discovery happens on the first chat message of a session, so a policy change needs a new conversation — a reused `session_id` shows a cached tool list and looks like the policy did not apply.

Least privilege is checkable directly: `kubectl exec deploy/customer-agent -- ls /data` should be `No such file or directory`. The orders volume moved to the MCP server.

### Lab 4 — deny-by-default per tool

```bash
make sandbox-forward   # needs keycloak :8085 and mcp-gateway :8081
cd modules/900-sandbox && . code-executor-mcp/.venv/bin/activate
python probe.py --url http://127.0.0.1:8081/mcp --user sam --tools-only
python probe.py --url http://127.0.0.1:8081/mcp --user ana --tools-only
```

Expected:

```
sam (support-associate)  ->  ['lookup_order', 'initiate_return']
ana (sales-analyst)      ->  ['lookup_order']
no token                 ->  HTTP 401 at the gateway
```

The two failure modes are different on purpose and both are worth showing. A bad token is a loud 401 before any tool logic runs. A valid token without the right makes the tool *vanish from `tools/list`*, so the model never learns the capability exists and cannot be talked into trying. `check_inventory` is in neither list: it is not denied by a rule, it is simply never allowed.

### Lab 5 — sandboxed execution

```bash
make sandbox-verify    # node kernel vs sandbox kernel
make sandbox-test      # broker over MCP, then the persona split
make sandbox-airgap    # hostile code in a CLAIMED sandbox, WITH a control
make sandbox-pool      # template, warm pool, live claims, labels, policies
make sandbox-lifecycle # claim -> run -> destroy -> refill, ~60s
make sandbox-unit      # 30 tests, no cluster
```

`make sandbox-verify` sleeps a fixed 12 seconds after creating the pod, so on a cold image pull it can print an empty `sandbox kernel:` line. That is the pod not being ready yet, not gVisor failing. Re-run it.

`make sandbox-unit` takes **3m43s** measured — most of it `uv pip install` into a fresh venv the first time. 30 passed.

**Read the output of `make sandbox-airgap` as a pair, never as one line:**

```
=== inside a CLAIMED sandbox (not a pooled one — see ADR 0006) ===
egress blocked: ConnectionRefusedError
sa token dir exists: False
kernel: 4.19.0-gvisor

=== CONTROL: same probe from a pod the policy does NOT select ===
CONTROL connected to 1.1.1.1:443 — the policy, not the runtime, is what blocks the sandbox
```

If the control does *not* connect, the "blocked" above it proves nothing — you may have a broken probe or a cluster with no egress at all rather than a working policy. This is the discipline the whole repo runs on; [TALK.md](TALK.md) explains what it caught.

A claimed sandbox reports `READY False` / `DependenciesNotReady` and shows `0/1` while it runs. That is the controller pulling the pod out of the warm pool's readiness accounting, not a fault.

End to end through the model, as a persona (needs `make sandbox-forward`):

```bash
make sandbox-ask USER_NAME=ana Q="What were total 2026-Q1 sales aggregated by region?"
make sandbox-ask USER_NAME=sam Q="What were total 2026-Q1 sales aggregated by region?"
```

`ana` gets four regional totals. `sam` says he has no access — not because he was refused, but because `run_python` never appeared in his tool list.

Charts need `MODEL_MAX_TOKENS=6144`, which the deployed ConfigMap sets. At the old fixed 2048 the model reasoned itself out of budget mid-tool-call and the turn ended with **no tool call, no answer, and no error** ([ADR 0007](adr/0007-tool-call-token-budget.md)). Watch for turns with reasoning and no `tool_use`; nothing that monitors tool errors will catch it.

### Labs 6-7 — issue to pull request

```bash
make gitea-ui          # http://127.0.0.1:3001/ , logins printed by `make gitea`
make coding-unit       # 22 tests, no cluster — measured 3.05s
make coding-issue TITLE="Add a /version endpoint" BODY="Return {\"version\": \"1.0.0\"}. Add a test."
make coding-watch      # dispatcher + sandbox logs
make coding-show N=3
```

Then the two verification targets, which are the actual lab:

```bash
make coding-egress-check   # limits 3 and 4, from a CLAIMED sandbox, with a control
make coding-token-check    # limit 2: mint -> 200 -> revoke -> 401 + a residue check
```

`coding-egress-check` is stricter than the lab-5 air-gap check, because an allowlist can fail by being too *narrow* and that failure is invisible unless the positive cases run too. Read all six rows:

```
=== inside the CLAIMED sandbox ===
  [ok  ] REACHED  AI gateway   (sandbox: reach)   ai-gateway.envoy-gateway-system...:80
  [ok  ] REACHED  Gitea        (sandbox: reach)   gitea-http.gitea...:3000
  [ok  ] blocked  kube API     (sandbox: block)   kubernetes.default...:443
  [ok  ] blocked  internet DNS (sandbox: block)   openrouter.ai:443
  [ok  ] service-account token dir exists: False
  kernel: 4.19.0-gvisor
=== CONTROL: same probe, a pod the policy does NOT select ===
  [ok  ] REACHED  internet DNS (sandbox: block)   openrouter.ai:443
  [ok  ] service-account token dir exists: True
```

`openrouter.ai:443` blocked while the model calls succeed is the point, not a contradiction: the coding agent talks to a hosted model *through the in-cluster gateway*, and the API key is held by the gateway.

Which agent runs is one environment variable on the dispatcher Deployment:

| `CODING_AGENT` | Needs | Note |
|---|---|---|
| `claude` | `MODEL_MAIN=remote-smart` — an OpenRouter key | the workshop's own agent, unpatched. qwen3:8b cannot drive it |
| `minimal` | nothing external | runs on the local 8B model, no account anywhere on the machine |

If Claude Code reports *"Request too large (max 32MB). Accumulated images and attachments…"*, there are no images and the limit is not 32 MB. It is a bare HTTP 413 from Envoy Gateway's default 32 KiB `connection.bufferLimit`, rendered through Claude Code's own error vocabulary. `platform/gateway/client-traffic-policy-buffer.yaml` fixes it and `make coding-platform` applies it.

---

## Restarting after a reboot

k3d nodes are containers. `k3d cluster start agentic` brings the cluster back, but **`runsc` does not survive `k3d cluster delete`** — it is copied into the node container by `scripts/install-gvisor.sh`. After any cluster *recreate*, re-run `make gvisor` before any sandbox pod schedules.

A rebuilt image is invisible to the warm pool until the pool recycles, because pooled pods are pinned to the old image id and `imagePullPolicy: Never` means nothing re-pulls. `make sandbox-images` and `make coding-images` both delete the pool pods for exactly this reason. If you build an image by hand, delete the pods yourself.

---

## Teardown

```bash
make down     # k3d cluster delete agentic  — destroys everything in-cluster
```

`make clean` is the same operation with `|| true`.

What `down` does **not** remove, and should be cleaned by hand if you want the disk back:

- Ollama models on the host (`ollama rm qwen3:8b llama3.2:1b`, ~6.5 GB)
- the locally built images (`customer-agent:local`, `chat-ui:local`, `mcp-server:local`, `python-runtime-sandbox:local`, `code-executor-mcp:local`, `coding-runtime-sandbox:local`, `coding-agent-dispatcher:local`)
- `.secrets/openrouter.key`, if you created one
- `data/orders.db` (gitignored, rebuilt by `make seed`)

---

## What was verified for this document, and what was not

The host's container engine was unresponsive while this was written — `docker ps -a` returned zero bytes after 240 and 500 second timeouts against a running OrbStack VM — so **nothing requiring the cluster could be run**.

Verified by running:

- `make coding-unit` — 22 passed in 3.05s
- `make sandbox-unit` — 30 passed in 223.20s (3m43s), plus two harmless deprecation warnings

Taken from the repo's own recorded output rather than re-run: every `kubectl`-dependent command, all seven labs' expected output, and the timings for the cold start. Those transcripts are in `README.md`, the module READMEs, and the ADRs, and they were produced against this cluster.

Not verified at all, because it is not written down anywhere: the agentgateway Helm chart name and version in [Labs 3 and 4](#labs-3-and-4--the-manual-part).
