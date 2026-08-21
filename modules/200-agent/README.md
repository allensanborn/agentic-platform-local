# Lab 1 — The agent, and the datastore that did not matter

> **No new control point.** This is the lab where the workshop's thesis gets its cleanest evidence, precisely because nothing was added.

Local port of the workshop's `200-strands-agents`. A Strands agent answers order questions, calls one tool, and streams its answer over SSE.

## Why this lab exists

Every other lab in this workshop adds infrastructure around the agent. This one builds the agent itself, so that you have something to put infrastructure around — and so that you can watch how little it changes from here on.

Read `agent.py` now and read it again after lab 3. That diff is the shortest version of the whole argument.

## What you run

```bash
make venv && make agent    # one-shot CLI, straight at the model
make deploy                # in-cluster: Deployment + ClusterIP Service
```

```
$ python agent.py "My order ID is ORD-1001. Where is it?"

Tool #1: lookup_order
Your order ORD-1001 is currently shipped and on its way!
  1 x Laptop Pro 15 ($1,299.99)  |  Tracking: 1Z999AA10123456784
  Estimated Delivery: July 8, 2026
```

## What to look at

**`agent.py` and `server.py` were copied verbatim from the workshop.** Not adapted — copied. They stayed byte-identical through lab 4. Lab 5 added exactly one line, making `max_tokens` read from an environment variable, and that one line turned out to be load-bearing ([ADR 0007](../../docs/adr/0007-tool-call-token-budget.md)).

**Removing AWS from this module took two edits, and neither is architectural:**

| File | Change |
|---|---|
| `tools.py` | DynamoDB `get_item` → SQLite `SELECT`. The `@tool` signature, the docstring, and the returned dict are byte-identical |
| `requirements.txt` | dropped `boto3`. That is the entire AWS dependency in the module |

The docstring matters more than it looks. The model reads it, so it is part of the tool's interface — which is exactly why it could not be allowed to drift when the datastore underneath changed.

**`k8s.yaml`, and specifically what is *not* in it.** There is no `serviceAccountName`. The workshop binds one to a DynamoDB IAM role via EKS Pod Identity; here there is no cloud IAM to bind, which is the point. Identity does not start mattering again until lab 4, and when it does it arrives as a JWT.

**`MODEL_BASE_URL` points at a ClusterIP, not at a model.** That is lab 0's control point doing its job: the agent talks to a Service and the gateway owns what that becomes.

## Heads up — the code in this directory is ahead of the lab

`agent.py` here is the **post-lab-3 version**. It no longer imports `lookup_order`; it connects to an MCP endpoint and calls `list_tools` at runtime. Likewise `k8s.yaml`'s ConfigMap already carries `MCP_SERVER_URLS`, `MODEL_MAX_TOKENS: "6144"` and the OTel variables that labs 2, 3 and 5 add.

That is deliberate — the repo holds one agent that grew a lab at a time, not seven frozen copies — but it means **you cannot read this directory as a snapshot of lab 1**. The lab-1 tool implementation is preserved as [`modules/500-mcp/mcp-server/tools-lab1-superseded.py`](../500-mcp/mcp-server/tools-lab1-superseded.py), which is where the DynamoDB → SQLite substitution above is actually visible.

The docstring at the top of `agent.py` explains what changed and why, including one piece of structure worth understanding early: the agent is built **per session**, not once at import. Strands' `MCPClient` binds its auth once, at transport connect, and binds each discovered tool to the client that listed it — so a single shared client cannot carry a per-user token. Building it per session in lab 3 means lab 4 adds a parameter instead of a redesign.

## What should surprise you

**Almost nothing about the agent was hard.** The model call worked first try. Tool selection worked first try — the model picked `lookup_order`, passed `ORD-1001`, and formatted the result faithfully.

**The single hardest thing in this lab was that qwen3 emits reasoning tokens by default.** Asked to "Reply with exactly: OK", it spent **72 completion tokens**, nearly all of it thinking, and returned empty `content` at `max_tokens: 20`. The budget was gone before any answer existed.

The workshop's agent sets `max_tokens: 1024`. With a reasoning model that is a **shared** budget, not an answer budget.

Two consequences, and the second is the one that comes back later:

- Do not diagnose an empty response as a broken tool call or a broken gateway. Check `usage.completion_tokens` and the `reasoning` field first.
- This is a *behavioural* difference from the workshop's Nova/Claude backends, not a configuration error. It is precisely the kind of thing a hybrid local/cloud gateway design exists to make visible.

Lab 5 is where this becomes a silent failure rather than a confusing one.

## What the substitution costs

| | Workshop | Here |
|---|---|---|
| Orders store | DynamoDB | SQLite, seeded by an `initContainer` into a shared `emptyDir` |
| Images | ECR + CodeBuild | local build + `k3d image import` |

**Preserved:** the tool contract, exactly. The datastore sits behind a function boundary the model never sees through.

**Cost:** nothing this workshop teaches. DynamoDB's operational properties are real and none of them are in scope. The dataset is the workshop's own 500 orders, converted out of DynamoDB's typed JSON.

## Go deeper

- [ADR 0003 — reasoning tokens](../../docs/adr/0003-reasoning-tokens.md)
- [TALK.md, Part 2](../../docs/TALK.md#part-2--lab-1-the-agent-and-the-datastore-that-did-not-matter)
- [RUNBOOK.md, Lab 1](../../docs/RUNBOOK.md#lab-1--the-agent-in-and-out-of-cluster)

**Next:** [Lab 1's other half — the chat UI](../300-ui/README.md).
