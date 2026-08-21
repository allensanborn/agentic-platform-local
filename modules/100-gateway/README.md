# Lab 0 — The model gateway

> **The control point: the gateway owns which model answers.**

The manifests for this lab live in [`platform/gateway/ai-gateway.yaml`](../../platform/gateway/ai-gateway.yaml), not in this directory, because the gateway is platform infrastructure that every later lab uses rather than a module the agent owns. This file is the lab guide; that file is the lab.

## Why this lab exists

An agent that names its own model has that choice baked into its image. Changing the model means changing code, rebuilding, and redeploying — and the credential for that model has to live somewhere the agent can reach.

The gateway takes both of those away. Agents ask for an **alias**. The gateway rewrites the alias to a real model, and holds whatever credential that model needs.

```
local-fast   -> llama3.2:1b
local-smart  -> qwen3:8b
```

That indirection looks like a small convenience in lab 0. It is the reason labs 6-7 can move a coding agent from an 8B model on your laptop to a 120B model in someone else's datacenter without touching the agent.

## What you run

```bash
make gw-forward         # separate shell — AI gateway on :8080
make agent-via-gateway
```

Then the payoff, live:

```bash
kubectl patch aigatewayroute local --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/modelNameOverride","value":"llama3.2:1b"}]'
```

Same alias. Same running agent, same pod, same image, same config. A different model is now answering.

## What to look at

**The alias table**, at the bottom of `ai-gateway.yaml`. Two `AIGatewayRoute` rules, each matching on the `x-ai-eg-model` header and rewriting it with `modelNameOverride`. The workshop's version of this table maps `claude-sonnet -> us.anthropic.claude-sonnet-4-5-20250929-v1:0`. Structurally it is the same object.

**`schema.name: OpenAI` on the `AIServiceBackend`.** This is the load-bearing field, and it is easy to read past. It declares "this backend speaks the OpenAI wire format," which is what makes Ollama, llama.cpp's `llama-server`, and vLLM all legal backends. It is the same field the workshop sets to `AWSBedrock`. The gateway is not special-casing local models; it is doing the job it was already doing.

**What is missing compared to the workshop:** the SigV4 signing hop. The workshop works hard so that the agent holds no model credential. Here that property is free, because there is no cloud credential to hold in the first place.

## What should surprise you

**The agent was never adapted for this.** `agent.py` routes every model call through an OpenAI-compatible base URL and ships `api_key="not-needed"` — that is the workshop's own code, unmodified. The seam this lab depends on was already there. This project only used it for something the workshop did not.

**The error message you are most likely to hit blames the wrong thing.** If every request returns

```
No matching route found. It is likely because the model specified in your
request is not configured in the Gateway.
```

while every CRD reports `Accepted=True`, the model configuration is fine. The real cause is almost certainly that Envoy Gateway was installed **without AI Gateway's `extensionManager` Helm values**. The AI Gateway controller runs as an Envoy Gateway xDS extension server, and that hook is what injects the `ext_proc` filter. Without the filter, the model name is never extracted from the request body into `x-ai-eg-model`, the header match cannot hit, and the request falls through to a not-found handler.

This blocked the project for hours and none of it was visible from the AWS-coupling analysis it started with. [ADR 0002](../../docs/adr/0002-ai-gateway-extproc-not-wired.md) has the full diagnosis. `make cluster` fetches the correct values file, so a clean build should not hit it.

**Two host-boundary traps, if you see `connection refused` reaching Ollama.** Ollama runs on the host, outside the cluster, because that is where the GPU is — see the [Deployment diagram](../../docs/architecture/). Two independent things break that hop:

| host | result |
|---|---|
| `host.docker.internal` | 200 |
| `host.k3d.internal` | connection refused |

`host.k3d.internal` is injected into CoreDNS by k3d and looks like the obvious choice, but on macOS it resolves to the Docker bridge gateway — the Linux VM, not the Mac where Ollama listens. And Ollama binds `127.0.0.1` by default; it must run as `OLLAMA_HOST=0.0.0.0:11434` (`make serve-model`).

## What the substitution costs

| | Workshop | Here |
|---|---|---|
| Model | Bedrock, signed with SigV4 via EKS Pod Identity | Ollama on the host |
| Gateway | Envoy AI Gateway | **the same**, unmodified |

**Preserved:** the whole hop, and slightly more than the workshop gets — the SigV4 hop disappears and the no-credential property comes for free.

**Cost:** model capability. An 8B model at Q4 is not Claude Sonnet. That bill does not come due until labs 6-7, where it comes due all at once.

## Go deeper

- [ADR 0002 — the extproc blocker](../../docs/adr/0002-ai-gateway-extproc-not-wired.md), including the zero-byte `curl` that produced a confidently wrong conclusion
- [ADR 0003 — reasoning tokens](../../docs/adr/0003-reasoning-tokens.md) — why `local-fast` is the better demo default
- [TALK.md, Part 1](../../docs/TALK.md#part-1--lab-0-the-model-gateway) — this lab as an argument
- [RUNBOOK.md, Lab 0](../../docs/RUNBOOK.md#lab-0--the-model-gateway-owns-which-model-answers) — verification commands

**Next:** [Lab 1 — the agent](../200-agent/README.md).
