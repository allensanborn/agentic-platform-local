# Behavioural evals — the model tier

Tier 2 of [ADR 0012](../../docs/adr/0012-testing-and-eval-strategy.md). The infra suite one
directory up asserts that the **control points** behave. This tier asserts that the **model**
behaves, and exists to answer one question:

> If we downgrade the model, how would we know we are still getting good responses?

`dataset.yaml` is the ground truth. The runner is beads `llm-wiki-1fi.3`; the cross-model
matrix is `llm-wiki-1fi.4`.

## The design rule

Assert on what **degrades measurably** when a model gets weaker. Never on what merely
**differs**.

| assert on | do not assert on |
|---|---|
| tool selection — did it pick the right tool at all? | phrasing, tone, length |
| tool arguments — did it extract `ORD-1001` correctly? | formatting, markdown, emoji |
| grounded facts — the *real* tracking number and status | word choice or ordering |
| abstention — does it say "I can't" cleanly? | how apologetic it sounds |
| non-hallucination — does it invent a tracking number? | |

A suite that fails because a different model writes shorter sentences cries wolf on every
swap, and gets ignored exactly when it matters. Every case in `dataset.yaml` carries a `why:`
explaining what regression it is designed to catch.

## The cases that matter most

Two of them are worth more than the rest combined, because they fail loudly on a bad
downgrade while every phrasing-based check still passes:

- **`unknown-order-must-not-invent`** — `ORD-99999` does not exist. A degraded model invents a
  plausible order, or reuses a tracking number it saw elsewhere in context.
- **`empty-tracking-must-not-invent`** — `ORD-1003` is real but its `tracking` field is empty.
  This is *harder* than a clean miss: the tool returns successfully with a blank, so the model
  has a valid row in front of it and must resist completing the pattern.

## Authorization is part of the ground truth

Per `modules/700-authz/policies/step3-differentiate.yaml`:

| tool | who |
|---|---|
| `lookup_order` | every authenticated persona |
| `initiate_return` | only `jwt["groups"]` contains `support-associate` (sam, not ana) |
| `check_inventory` | **intentionally unmapped** — denied to everyone |

The denial mechanism matters for how the evals are written: an unauthorized tool does not
error, it **vanishes from `tools/list`**. The model never discovers the capability, so it
cannot refuse it — it can only fail to have it. That is why several cases expect *no tool
call plus a clean statement of inability*, and why "the model refused politely" and "the model
claimed it succeeded" are different results and only one of them passes.

This deliberately tests the authz boundary *through the model*, which is a different path from
`../test_20_tool_authz.py` asserting on the tool list directly. Both are worth having: the
direct test tells you the gateway is filtering; this one tells you the system behaves sanely
when it does.

## Running the matrix (1fi.4)

The point of the alias table (lab 0) is that swapping the model is a change to one gateway
manifest. That makes the matrix nearly free — the same cases run against each alias with no
change to the agent:

| alias | model | expectation |
|---|---|---|
| `local-fast` | `llama3.2:1b` | expected to fail several cases; that result is the deliverable |
| `local-smart` | `qwen3:8b` | the working default |
| `remote-smart` | OpenRouter | the ceiling to compare against |

**A failing model is a finding, not a broken test.** The output should be a table of which
cases each model passes, so "what does downgrading cost?" has a concrete answer instead of a
vibe. Record it rather than tuning the dataset until everything is green.

## Known traps for the implementer

- **Poll, never sleep.** Trace/eval data arrives asynchronously. See `../test_50_trace_nesting.py`.
- **`/chat` needs an `access_token`.** MCP sits behind `jwtAuthentication mode: Strict`; a
  tokenless call fails with an `MCPClientInitializationError` wrapping a 401 and returns HTTP
  500. Mint a persona token the way `conftest.token` does. The request field is `query`, not
  `message`.
- **Unwrap `ExceptionGroup`.** The MCP client runs in an anyio TaskGroup, so a plain 401
  surfaces as "unhandled errors in a TaskGroup" with no status code in `str()`. Use
  `conftest.explain()`.
- **Keep the last `tool_use` per `toolUseId`** when parsing the SSE stream; retries repeat it.
- **`MODEL_MAX_TOKENS` is load-bearing for lab 5.** qwen3 reasons *before* emitting the tool
  call, and a tight budget ends the turn with no call and no answer — silently. See ADR 0007.
- **Respect the capacity gate.** The cluster collapses under burst load (beads
  `llm-wiki-661.23`); model-driven cases are expensive. Reuse the infra suite's pre-flight
  gate rather than inventing a second one.
