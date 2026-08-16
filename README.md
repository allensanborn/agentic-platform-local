# agentic-platform-local

Rebuilding AWS's **Secure AI Agents on Amazon EKS** workshop from open-source parts on a single consumer machine. No EKS, no AWS, no cloud model required.

The workshop's thesis is that every capability arrives as **a control point in infrastructure, not a smarter or more-trusted agent** — the agent's code barely changes lab to lab; what changes is what surrounds it. That thesis is portable. This repo tests how much of it survives on one laptop.

Full feasibility evaluation, including the AWS-coupling analysis and what each lab costs to reproduce, lives in the companion wiki at `wiki/homelab-agentic-platform-plan.md`.

**Two documents carry the rest of this repo:**

- **[docs/RUNBOOK.md](docs/RUNBOOK.md)** — clone to working demo. Prerequisites, the cold-start order and why it is not cosmetic, the manual steps `up-all` deliberately leaves out, how to verify each lab, where a step is slow rather than hung, and teardown.
- **[docs/TALK.md](docs/TALK.md)** — the substitution table as an argument. Lab by lab, what each substitution preserves and what it costs, including the parts that failed: the fail-open air-gap policy in the workshop's own design, what gVisor gives up against Firecracker, and a sizing claim that was retracted after being measured.

## Status

| Lab | Component | Status |
|---|---|---|
| 0 | Model gateway (Envoy AI Gateway → Ollama), alias table | ✅ **working** |
| 1 | Strands agent + `lookup_order` tool + SSE + Chainlit UI, all in-cluster | ✅ **working** |
| 2 | Observability: OTel + collector → **Langfuse** | ✅ **working** — one `/chat` turn is a single 26-observation trace spanning agent *and* gateway |
| 3 | MCP tool serving via agentgateway + least privilege | ✅ **working**, ⚠️ **not automated** — see below |
| 4 | Authorization: Keycloak + deny-by-default per-tool policy | ✅ **working**, ⚠️ **not automated** — see below |
| 5 | Sandboxed code execution | ✅ **working** (gVisor not Firecracker — [ADR 0005](docs/adr/0005-gvisor-not-kata-firecracker.md)) |
| 6-7 | Autonomous coding agent: Gitea issue → sandbox → PR | ✅ **working** ([ADR 0009](docs/adr/0009-coding-agent-is-a-swappable-command.md)) |

⚠️ **Labs 3 and 4 have complete manifests and no Makefile target.** `make images` does not build `mcp-server:local`, `make deploy` applies neither `modules/500-mcp/mcp-server/k8s.yaml` nor `modules/700-authz/policies/step3-differentiate.yaml`, and nothing in this repo installs the agentgateway control plane — those steps were run by hand and never scripted. Since lab 3 the agent discovers its tools over MCP instead of importing them, so a cluster built from `make up-all` alone gives you an agent with **zero tools**. [docs/RUNBOOK.md](docs/RUNBOOK.md#labs-3-and-4--the-manual-part) has the manual sequence.

**What actually runs today:** a Strands agent answering order questions against a local SQLite database, reaching its model *through the gateway by alias*, streaming SSE with the workshop's exact wire contract.

The headline demo — swapping the model under a running agent with no code, image, or config change:

```bash
$ kubectl patch aigatewayroute local --type=json \
    -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/modelNameOverride","value":"llama3.2:1b"}]'

# same alias, same agent, different model now answering
local-fast   -> llama3.2:1b
local-smart  -> qwen3:8b
```

**Lab 4 — the same agent, two personas, different capabilities:**

```
sam (support-associate)  ->  Discovered 2 MCP tools: ['lookup_order', 'initiate_return']
ana (sales-analyst)      ->  Discovered 1 MCP tools: ['lookup_order']
no token                 ->  HTTP 401 at the gateway
```

`check_inventory` is not denied by a rule — it is simply never allowed. An `Allow` list that
matches nothing denies everything, so an unmapped tool is invisible to everyone. And note the
failure modes differ: a bad token is a loud 401, while a valid token without the right makes
the tool *vanish from `tools/list`* — the model never learns the capability exists, so it
cannot be talked into trying.

**Lab 5 — the agent writes code and something else runs it:**

```
$ make sandbox-ask USER_NAME=ana Q="What were total 2026-Q1 sales aggregated by region?"

Tool #1: run_python          # 139 rows fetched by the broker, never through the model
Central: $17,494.04   East: $16,014.34   South: $25,758.73   West: $34,793.56

$ make sandbox-ask USER_NAME=sam Q="What were total 2026-Q1 sales aggregated by region?"

I don't have access to sales data or reporting capabilities. My current tools only allow
me to check order status and initiate returns.
```

`sam` is not refused. `run_python` is simply not in the tool list his token produces, so the
model has no capability to be talked out of. And the code that *did* run, ran with its own
kernel, no network, and no Kubernetes credential:

```
$ make sandbox-airgap
egress blocked: ConnectionRefusedError
sa token dir exists: False
kernel: 4.19.0-gvisor
=== CONTROL: same probe from a pod the policy does NOT select ===
CONTROL connected to 1.1.1.1:443 — the policy, not the runtime, is what blocks the sandbox
```

**Labs 6-7 — a labelled issue becomes a pull request, and nobody hands the agent a credential:**

```
$ make coding-issue TITLE="Add a /version endpoint" BODY="Return {\"version\": \"1.0.0\"}. Add a test."
filed issue #3 -> labelled 'agent' -> webhook fired

$ make coding-show N=3
  [coding-agent-bot] 🤖 Working on this in an isolated sandbox…
  [coding-agent-bot] ✅ Opened PR #4: .../pulls/4
  #4  Fix issue #3    open <- agent/issue-3   ### Tests passed | 2 passed
```

The agent commits. The **wrapper** pushes and opens the PR, because the push credential was
never in the agent's hands. The PR is where a human enters, and the agent's job ends there.

```
$ make coding-egress-check
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

$ make coding-token-check      # the token the sandbox actually used, after the run
  after the run, does it authenticate?  HTTP 401
```

Note `openrouter.ai` blocked while the model calls succeed: the coding agent talks to a
hosted model, and the API key is held by the **gateway**, never by the sandbox.

```
$ python agent.py "My order ID is ORD-1001. Where is it?"

Tool #1: lookup_order
Your order ORD-1001 is currently shipped and on its way!
  1 x Laptop Pro 15 ($1,299.99)  |  Tracking: 1Z999AA10123456784
  Estimated Delivery: July 8, 2026
```

## The interesting part: how little had to change

`agent.py` and `server.py` were **copied verbatim** from the workshop. Not adapted — copied. (Through lab 4 they stayed that way; lab 5 added exactly one line to `agent.py`, making `max_tokens` an environment variable — see [ADR 0007](docs/adr/0007-tool-call-token-budget.md) for why that turned out to be load-bearing.) They work unmodified against a local model because the workshop already routes every model call through an OpenAI-compatible base URL, and the agent ships with `api_key="not-needed"`.

Exactly two things changed to remove AWS entirely:

| File | Change |
|---|---|
| `tools.py` | DynamoDB `get_item` → SQLite `SELECT`. The `@tool` signature, docstring, and returned dict are byte-identical, because the tool contract is the interface and the datastore is an implementation detail. |
| `requirements.txt` | dropped `boto3`. That is the whole AWS dependency in this module. |

The dataset is the workshop's own 500 orders, converted out of DynamoDB's typed JSON.

## Quick start

Prerequisites: Docker (OrbStack here), `k3d`, `kubectl`, `helm`, `ollama`, `uv`, Python 3.12, and ~8 GB free for models and images.

**[docs/RUNBOOK.md](docs/RUNBOOK.md) is the full version** — cold-start ordering, which stages look hung and are not, and per-lab verification. The short version:

```bash
make up-all       # cluster, gVisor, sandbox control plane, Langfuse, Keycloak,
                  # Gitea, images, agent, UI, broker, coding dispatcher.
                  # 20-40 min cold. Order is load-bearing; see the comment block.

make model                 # ollama pull qwen3:8b  (~5 GB)  -> alias local-smart
ollama pull llama3.2:1b    #                       (~1.3 GB) -> alias local-fast
make serve-model  # separate shell: Ollama bound to 0.0.0.0 so the cluster can reach it
make ui           # separate shell: http://127.0.0.1:8000
```

Then the manual lab-3/lab-4 steps in the run-book, without which the agent has no tools.

`make up` (cluster + images + deploy) is labs 0-1 only, and no longer produces a working chat on its own — the agent's ConfigMap points `MCP_SERVER_URLS` at the agentgateway that `up` does not install.

**Do not run `make gvisor` or `make up-all` against a cluster you are using.** `gvisor` restarts the k3d agent node. On an already-running cluster prefer the sub-targets.

Individual bring-ups, if you would rather go lab by lab:

```bash
make sandbox          # lab 5: gVisor + agent-sandbox control plane + images + broker + authz policy
make sandbox-forward  # in another shell: the port-forwards the verification targets need
make sandbox-test     # then see modules/900-sandbox/README.md

make gitea            # labs 6-7: Gitea + bot account + seed repo + label + webhook (prints logins)
make coding           # sandbox template/pool, egress lock, images, dispatcher
make gitea-ui         # in another shell: http://127.0.0.1:3001/
make coding-issue TITLE="Add a /health endpoint" BODY="Return {\"status\": \"ok\"}."
```

Optional — run the real Claude Code CLI against a free hosted model:

```bash
printf '%s' 'sk-or-v1-...' > .secrets/openrouter.key   # gitignored
make model-key
kubectl apply -f platform/gateway/openrouter.yaml      # `make model-remote` is broken; see below
make model-remote-test
```

> Known break: `make model-remote`'s first line is `kubectl rollout status -n model-access deploy/openrouter (direct TLS) --timeout=180s` — a leftover from removing the nginx TLS-origination sidecar. There is no such Deployment any more and the parenthetical is not valid shell. Apply the manifest directly until that line is deleted.

See [modules/1000-coding-agent/README.md](modules/1000-coding-agent/README.md) for the four
limits and where each one is enforced.

Diagrams: `make diagrams` (see [docs/architecture](docs/architecture/)).

## Design decisions

- [ADR 0001 — k3s (via k3d), not kind](docs/adr/0001-k3s-not-kind.md) — kindnet silently ignores NetworkPolicy, which would make lab 5's airgap demo *look* like it works while enforcing nothing.
- [ADR 0002 — Envoy AI Gateway extproc is not wired into the filter chain](docs/adr/0002-ai-gateway-extproc-not-wired.md) — **resolved.** The lab-0 blocker, with the exact diagnostic, and the zero-byte `curl` that produced a confidently wrong conclusion.
- [ADR 0003 — local model reasoning tokens](docs/adr/0003-reasoning-tokens.md) — qwen3 emits reasoning by default; this has real consequences for `max_tokens` and multi-turn.
- [ADR 0004 — observability backend, and the gateway-span gap](docs/adr/0004-observability-backend-and-gateway-spans.md) — **superseded in part by 0008.** Kept for how it failed: a gap declared, theorised about, and measured against a backend that had been deleted.
- [ADR 0005 — gVisor, not Kata + Firecracker](docs/adr/0005-gvisor-not-kata-firecracker.md) — the one substitution lab 5 forces, and exactly what it costs.
- [ADR 0006 — install upstream agent-sandbox](docs/adr/0006-upstream-agent-sandbox-control-plane.md) — it runs unmodified on arm64/k3s. Includes a real hole found in the workshop's own air-gap NetworkPolicy.
- [ADR 0007 — `max_tokens` is a per-tool property](docs/adr/0007-tool-call-token-budget.md) — adding a tool whose argument is a whole program is a change to the model config, and the failure is silent.
- [ADR 0008 — Langfuse fits after all, at 1.6 GiB](docs/adr/0008-langfuse-fits-after-all.md) — a production sizing *recommendation* read as a requirement. The gap was a factor of eight.
- [ADR 0009 — the coding agent is a swappable command](docs/adr/0009-coding-agent-is-a-swappable-command.md) — the AI gateway, not a sidecar proxy, is the Anthropic-compatibility layer; and the lab's four limits are properties of the boundary, not of which agent binary sits inside it.
- [ADR 0010 — drop Traefik; the cleartext hop was a version gap](docs/adr/0010-no-traefik-and-the-backendtlspolicy-version-gap.md) — a resource that applies successfully and is then silently ignored is worse than one that fails.

## What this cannot do

Reproducing lab 5 faithfully requires **Kata Containers + Firecracker microVMs**, which need
`/dev/kvm`. That is architecturally unavailable on both targets: Windows/WSL2 runs under
Hyper-V, which does not support nested non-Hyper-V hypervisors, and Apple Silicon has no KVM
path at all. The substitute is gVisor via `RuntimeClass` — every manifest, the warm pool, the
air-gap NetworkPolicy and the whole data-in-as-a-file discipline survive unchanged, but the
workshop's claim that *"a process that escapes the container escapes into a VM, not onto the
node"* stops being true. [ADR 0005](docs/adr/0005-gvisor-not-kata-firecracker.md) has the
full comparison rather than papering over it.

Everything else in lab 5 is the workshop's own software: the upstream `agent-sandbox`
controller, CRDs, router and Python SDK, installed unmodified.
