# Lab 1 (continued) — The chat UI

> **No new control point.** A Chainlit front end over the agent's SSE stream, so that every later lab has somewhere to be *seen* happening.

Local port of the workshop's `ui/app.py`.

## Why this lab exists

Labs 3, 4 and 5 are about what a caller is allowed to see. That is much easier to believe when you watch two personas ask the same question in the same interface and get different capabilities, than when you read two `probe.py` outputs side by side.

The UI is also the only place the lab-5 chart is visible at all — it comes back as bytes behind a short `chart_id`, and something has to render it.

## What you run

```bash
make ui        # separate shell — port-forward svc/chat-ui 8000
               # http://127.0.0.1:8000
```

Out of cluster, pointing at a local agent:

```bash
AGENT_URL=http://127.0.0.1:8080/chat chainlit run app.py
```

## What to look at

**`StreamRenderer` and `ChainlitUI` are copied verbatim from the workshop.** They implement the SSE wire contract that every lab's `server.py` shares, and that contract is the interesting part of this module:

| Event | Meaning |
|---|---|
| `token` | answer text delta |
| `reasoning` | reasoning text delta, rendered as a separate collapsible step |
| `tool_use.input` | **accumulated so far** — replace the rendered value, do not concatenate |
| `tool_result` | closes a step, matched by id |
| `image` | the lab-5 chart |

`tool_use.input` is the one that bites people writing their own client. The field carries the whole argument as built so far, not the newest fragment. Concatenating produces a garbled, ever-growing blob that looks like a model failure and is not.

**`REQUEST_TIMEOUT = 300`.** A local 8B model is slower than Bedrock, and slower again when it reasons before every tool call. The workshop's timeout is not generous enough here.

## What should surprise you

**The workshop's Cognito login screen is deliberately absent.**

The workshop's UI gates on Cognito OAuth and extracts a persona from the token. That machinery exists to feed per-tool authorization — and until lab 3 moves tools behind agentgateway, **there is nothing to authorize**. Adding an identity provider at this point would be ceremony in front of a control point that does not exist yet.

So it arrives with the lab that needs it, which is lab 4. This is worth noticing as a piece of *pedagogical* design rather than an omission: the workshop's ordering makes each control point observable the moment it is introduced, and a login screen in lab 1 would break that by making the interesting behaviour show up three labs after the code that produces it.

**The tool name stays visible in the UI on purpose.** Step labels read "Used code sandbox (`run_python`)" rather than a friendly name alone. This is a workshop about building agents; a participant should always be able to see which tool fired.

## What the substitution costs

Nothing. There is no AWS in this module to remove — the only workshop-specific piece was the Cognito gate, and that moved to lab 4 rather than disappearing.

## Go deeper

- [`modules/200-agent/README.md`](../200-agent/README.md) — the agent behind this UI
- [RUNBOOK.md — the manual steps](../../docs/RUNBOOK.md#the-manual-steps-up-all-deliberately-leaves-out), including why `make ui` needs its own shell

**Next:** [Lab 2 — observability](../400-observability/README.md).
