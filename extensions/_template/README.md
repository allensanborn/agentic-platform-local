# NNN — <name>

**Seam:** `<seam>` · **Status:** proposed | building | working
**Base required:** labs <which>, via `make <targets>`
**Requires extensions:** none | NNN (<seam state it actually depends on>)
**Alternative to:** none | NNN (same seam)

## What this demonstrates

One paragraph: the capability, stated as a control point in infrastructure — never as a smarter or more-trusted agent.

## The substitution

| | Base | This extension |
|---|---|---|
| `<seam>` | <what's there> | <what replaces it> |

What is preserved (the contract that does not move) and what it costs.

## Plan

Numbered, smallest-observable-step first. The first step is always: bring up the base state and run its verify, so a later failure is attributable to the extension.

## Verify

`make ext-<name>-verify`. Every enforcement claim ships with its positive control.

## Grounding

Wiki pages / sources this extension is built from.
