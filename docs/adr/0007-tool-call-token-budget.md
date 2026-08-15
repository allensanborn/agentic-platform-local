# ADR 0007 — `max_tokens` is a per-tool property, not a global constant

**Status:** accepted
**Date:** 2026-08-15

## Context

ADR 0003 established that qwen3 emits reasoning tokens by default and that this has real
consequences for `max_tokens`. Lab 5 turned that from a consideration into a hard failure,
and the failure mode is worth writing down because it is silent.

`run_python`'s `code` argument is an entire Python program. It is the largest tool argument
in this repo by an order of magnitude — `lookup_order` takes an order ID. And qwen3 spends
its budget on reasoning *before* it emits the tool call, so the reasoning block and the
generated program compete for the same allowance.

At the repo's previous fixed `max_tokens: 2048`, this was the measured behaviour of a
charting request, twice in a row:

```
--- attempt 1
reasoning chars=2313 answer chars=0 tools=None
--- attempt 2
reasoning chars=1496 answer chars=0 tools=None
```

The agent log shows the model reasoning correctly and completely — it picks `run_python`,
plans the pandas, plans the matplotlib, and ends with *"Let me put this into the function
call with the correct parameters."* Then the turn ends. No `tool_use` event, no answer, no
error. The user sees nothing.

The same model at the same settings answered the *text* version of the question perfectly,
matching the broker's direct-MCP output to the cent. So this is not "the local model cannot
chain tools". It is one tool whose argument does not fit.

## Decision

`max_tokens` becomes an environment variable, `MODEL_MAX_TOKENS`, defaulting to the previous
2048. The lab-5 deployment sets it to 6144.

## Evidence it is the right diagnosis

Same prompt, same model, same everything else, at 6144:

```
--- MODEL_MAX_TOKENS=6144 chart attempt 1
reasoning chars=2195 answer chars=280 tools={'run_python'}
--- MODEL_MAX_TOKENS=6144 chart attempt 2
reasoning chars=4042 answer chars=420 tools={'run_python'}
```

Note attempt 2: 4042 characters of reasoning, which alone exceeds what the 2048 budget could
have held together with a program.

## Consequences

- A budget that is adequate for a tool catalogue is not adequate for the *next* tool added to
  it. Adding a tool whose arguments are large is a change to the model configuration, whether
  or not anyone treats it as one.
- The failure is silent by construction: budget exhaustion mid-tool-call produces an empty
  turn, not an exception. Anything that watches for tool errors will see nothing. Watch for
  turns that produce reasoning and no `tool_use`.
- This is a local-model constraint, not a workshop one. A frontier model behind the same
  gateway has a budget where this does not arise, which is exactly why the workshop's own
  code never had to expose the knob.
