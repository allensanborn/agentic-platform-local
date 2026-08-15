# agentic-platform-local

Rebuilding AWS's **Secure AI Agents on Amazon EKS** workshop from open-source parts on a single consumer machine. No EKS, no AWS, no cloud model required.

The workshop's thesis is that every capability arrives as **a control point in infrastructure, not a smarter or more-trusted agent** — the agent's code barely changes lab to lab; what changes is what surrounds it. That thesis is portable. This repo tests how much of it survives on one laptop.

Full feasibility evaluation, including the AWS-coupling analysis and what each lab costs to reproduce, lives in the companion wiki at `wiki/homelab-agentic-platform-plan.md`.

## Status

| Lab | Component | Status |
|---|---|---|
| 0 | Model gateway (Envoy AI Gateway → Ollama) | ⚠️ **blocked** — see [ADR 0002](docs/adr/0002-ai-gateway-extproc-not-wired.md) |
| 1 | Strands agent + `lookup_order` tool + SSE | ✅ **working** |
| 2 | Observability (Langfuse / OTel) | not started |
| 3 | MCP tool serving | not started |
| 4 | Authorization (Keycloak + AgentgatewayPolicy) | not started |
| 5 | Sandboxed code execution | not started |
| 6-7 | Autonomous coding agent | not started |

**What actually runs today:** a Strands agent answering order questions against a local SQLite database, driven by `qwen3:8b` on Ollama, streaming SSE with the workshop's exact wire contract.

```
$ python agent.py "My order ID is ORD-1001. Where is it?"

Tool #1: lookup_order
Your order ORD-1001 is currently shipped and on its way!
  1 x Laptop Pro 15 ($1,299.99)  |  Tracking: 1Z999AA10123456784
  Estimated Delivery: July 8, 2026
```

## The interesting part: how little had to change

`agent.py` and `server.py` are **copied verbatim** from the workshop. Not adapted — copied. They work unmodified against a local model because the workshop already routes every model call through an OpenAI-compatible base URL, and the agent ships with `api_key="not-needed"`.

Exactly two things changed to remove AWS entirely:

| File | Change |
|---|---|
| `tools.py` | DynamoDB `get_item` → SQLite `SELECT`. The `@tool` signature, docstring, and returned dict are byte-identical, because the tool contract is the interface and the datastore is an implementation detail. |
| `requirements.txt` | dropped `boto3`. That is the whole AWS dependency in this module. |

The dataset is the workshop's own 500 orders, converted out of DynamoDB's typed JSON.

## Quick start

Prerequisites: Docker, `k3d`, `ollama`, `uv`, Python 3.12.

```bash
make seed        # build data/orders.db from the workshop dataset
make model       # ollama pull qwen3:8b (~5GB)
make agent       # run the agent against Ollama directly
make serve       # FastAPI + SSE on :8081
make cluster     # k3d cluster + Envoy AI Gateway (lab 0 — see ADR 0002)
```

## Design decisions

- [ADR 0001 — k3s (via k3d), not kind](docs/adr/0001-k3s-not-kind.md) — kindnet silently ignores NetworkPolicy, which would make lab 5's airgap demo *look* like it works while enforcing nothing.
- [ADR 0002 — Envoy AI Gateway extproc is not wired into the filter chain](docs/adr/0002-ai-gateway-extproc-not-wired.md) — the current lab-0 blocker, with the exact diagnostic.
- [ADR 0003 — local model reasoning tokens](docs/adr/0003-reasoning-tokens.md) — qwen3 emits reasoning by default; this has real consequences for `max_tokens` and multi-turn.

## What this cannot do

Reproducing lab 5 faithfully requires **Kata Containers + Firecracker microVMs**, which need `/dev/kvm`. That is architecturally unavailable on both targets: Windows/WSL2 runs under Hyper-V, which does not support nested non-Hyper-V hypervisors, and Apple Silicon has no KVM path at all. The plan substitutes gVisor via `RuntimeClass` — every manifest, the warm pool, the airgap NetworkPolicy and the whole data-in-as-a-file discipline survive unchanged, but the workshop's claim that *"a process that escapes the container escapes into a VM, not onto the node"* stops being true. That trade is documented rather than papered over.
