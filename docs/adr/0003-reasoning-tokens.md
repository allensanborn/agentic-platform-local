# ADR 0003 — local reasoning models and the token budget

**Status:** accepted
**Date:** 2026-08-15

## Observation

`qwen3:8b` emits reasoning tokens by default. Asking it to "Reply with exactly: OK" spent
**72 completion tokens**, nearly all of it thinking, and returned an empty `content` when
`max_tokens` was set to 20 — the budget was consumed before any answer was produced.

The workshop's agent sets `params={"max_tokens": 1024}`. With a reasoning model that is a
shared budget, not an answer budget.

Ollama surfaces the split as a separate `reasoning` field alongside `content`. Strands
also logs `reasoningContent is not supported in multi-turn conversations with the Chat
Completions API`, so reasoning is dropped between turns rather than accumulated.

## Consequences

- Do not diagnose an empty response as a broken tool call or a broken gateway. Check
  `usage.completion_tokens` and the `reasoning` field first.
- Keep `max_tokens` generous locally, or disable thinking for tool-calling paths where
  latency matters more than deliberation.
- This is a *behavioural* difference from the workshop's Nova/Claude backends, not a
  configuration error, and it is the kind of thing the hybrid local/cloud gateway design
  exists to make visible.

## Related

Tool selection itself worked correctly on the first attempt — the model chose
`lookup_order`, passed `ORD-1001`, and formatted the result faithfully. The predicted
weakness of small models at *multi-turn, multi-tool* chaining is not yet exercised;
that arrives with lab 3.
