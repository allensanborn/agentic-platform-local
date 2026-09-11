# 070 — Dapr Workflow + Dapr Agents: durable orchestration with the authz stack on

**Seam:** `orchestration` · **Status:** proposed
**Base required:** labs 0-7
**Requires extensions:** 010 (per-use token minting at a boundary); 030 strongly recommended (typed grants are what make durability *safe* to add)
**Alternative to:** the module-1000 dispatcher's ad-hoc control loop

## What this demonstrates

The compounding payoff of the whole extensions layer, and the significant one. The base's coding agent is orchestrated by a hand-rolled control loop: webhook → dispatcher → claim sandbox → run → PR → revoke, with every failure path written by hand. This extension re-drives it as a **Dapr Workflow** whose activities are the same steps, with the agent hops as **Dapr Agents** — durable, replayable, resumable across crashes — while the authz extensions stay enforced at every activity boundary.

What makes this more than a workflow-engine swap is the interaction the wiki worked out between durability and credentials, which this extension exists to demonstrate:

- **The lifetime mismatch inverts the naive design.** Workflows live for hours-to-months; tokens for minutes. So the durable artifact must be the **grant** (030's typed `authorization_details`), and tokens are minted per-use *inside* the activity (via 010) and never persisted.
- **History hygiene is two problems, not one.** Business payloads in event-sourced history are an encryption problem. Tokens are a *correctness* problem: replay returns cached activity results, so an activity that returns a token returns the same expired token forever. The rule is forced, not chosen: **a credential never crosses an activity boundary as a return value.** The demo makes the failure visible on purpose — one deliberately-wrong activity that returns a token, replayed after expiry, beside the correct grant-carrying design.
- Dapr compounds the stakes: workflow actor state persists in the state store after completion, so anything that crossed a boundary is durable whether you wanted it or not.

The control point: the workflow history. Every agentic step is a recorded, replayable activity with the grant that authorized it — the traceability story lab 2 started, extended to *authority*, not just spans.

## The substitution

| | Base | This extension |
|---|---|---|
| `orchestration` | dispatcher's in-process loop; crash = lost run | Dapr Workflow (event-sourced, deterministic replay); crash = resume |
| agent hops | direct HTTP/A2A calls | Dapr Agents / service invocation, same gateways still in the path |

Preserved: the sandbox, the gateways, per-tool authz, the PR-as-human-boundary. Cost: Dapr control plane on the cluster; determinism constraints on orchestrator code; and the discipline above, which is the point.

## Plan

1. Base up through module 1000; one successful `make coding-issue` run as the before.
2. Dapr on k3s; the dispatcher's steps become activities 1:1 — no behavior change, crash-resume now demonstrable (`kubectl delete pod` mid-run, run completes).
3. Grants become durable: the workflow input carries the 030 grant; each activity mints its token per-use via 010. Assert the workflow history contains **zero tokens** (grep the state store — that assertion is a test).
4. The deliberate-failure exhibit (expired-token-from-history), kept as a permanently failing example with commentary.
5. Agent hops onto Dapr Agents; Langfuse spans now nest under workflow/activity spans.

## Verify

- mid-run pod kill → the run resumes and the PR lands; **positive control:** the base dispatcher under the same kill loses the run
- state-store grep: grants present, tokens absent — after both success and failure paths (failure payloads/stack traces included)
- every activity's trace carries the grant that authorized it; an off-grant activity input is refused at the boundary (030's error, now inside a workflow)

## Grounding

wiki: `durable-workflow-authorization` (the design this implements: grant-as-durable-artifact, history hygiene, activity-signature-as-typed-transaction), `dapr-agentic-campaign-demo-plan` (the sibling plan this composes with — that one re-drives the Floci campaign; this one re-drives the workshop's coding agent), `agent-authorization-stack-2026` (Okta XAA context: IdP-layer identity cannot see an orchestration boundary — this seam is exactly what it cannot reach), `durable-execution`. Note for the docs: Dapr Agents began as *Floki* — no relation to Floci (020); own the coincidence in one line and move on.
