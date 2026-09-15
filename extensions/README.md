# Extensions — composing past the workshop

The base workshop (labs 0-7, `modules/`) is **frozen**: it is the faithful port, it works, and nothing in this directory modifies it. Extensions build *on* it the same way the labs built on each other — by swapping or adding exactly one thing at a seam the base already proved was a seam.

**You never redo the base.** Every extension starts from a running `make up-all` cluster and states precisely which labs it needs. The repo's own headline demo — retargeting a live agent by patching one gateway alias — is the pattern generalized here: the base is a set of named seams, and an extension is one substitution at one seam.

## The seams

The base workshop demonstrated each of these is swappable without touching the agent. Extensions swap them on purpose.

| Seam | What sits there in the base | Proven swappable by |
|---|---|---|
| `model` | Ollama behind the AI gateway alias table | lab 0's `modelNameOverride` patch |
| `datastore` | SQLite behind the `@tool` contract | the port itself (DynamoDB → SQLite, tool signature byte-identical) |
| `identity` | Keycloak issuing persona JWTs | the port itself (Cognito → Keycloak: two strings + one claim) |
| `tool-gateway` | agentgateway (MCP proxy, per-tool authz) | lab 3-4's design: the agent discovers tools, it doesn't import them |
| `secrets` | raw K8s Secrets (`coding-agent-creds`, Langfuse) | dispatcher already mints/revokes per-run — dynamic secrets by hand |
| `orchestration` | none — the dispatcher is an ad-hoc control loop | module 1000 isolates it: webhook → dispatcher → sandbox → PR |
| `grant-shape` | coarse persona claims (`groups`) mapped to tool allowlists | lab 4's deny-by-default policy structure |
| `observability` | Langfuse behind the OTel collector | lab 2's design: workloads speak OTLP to the collector and hold no backend credential (and the port already swapped Jaeger out once) |

## Composition rules

1. **Two extensions that swap *different* seams compose.** Install both; nothing coordinates them beyond the base contracts.
2. **Two extensions that swap the *same* seam are alternatives.** You pick one per cluster (e.g. Keycloak+token-exchange vs Cognito-on-Floci at `identity`).
3. **An extension may require another** (declared in its header). The dependency is on the *seam state*, not the implementation — `070-dapr` needs *an* identity seam that can do RFC 8693, not specifically Keycloak.
4. **An extension never edits `modules/`.** If it needs the base to change, that change lands in the base as its own commit first, justified on the base's own terms.

## The extensions

| # | Extension | Seam | Status | One line |
|---|---|---|---|---|
| 010 | [Token exchange (RFC 8693)](010-token-exchange/README.md) | `identity` | proposed | the gateway trades the user's token for a narrower per-tool token; the delegation chain shows up in the trace |
| 020 | [Floci: the un-substitution](020-floci-cloud/README.md) | `identity`+`datastore`+`model` | proposed | restore the workshop's verbatim AWS code paths against locally emulated AWS |
| 030 | [Typed intent (RFC 9396 RAR)](030-typed-intent-rar/README.md) | `grant-shape` | proposed | bind a grant to one typed transaction; show where that model ends and containment begins |
| 040 | [SPIFFE/SPIRE workload identity](040-spiffe-workload-identity/README.md) | `identity` (workload half) | proposed | attested, rotating SVIDs and mTLS replace every mounted credential |
| 050 | [Pomerium as MCP gateway](050-pomerium-mcp-gateway/README.md) | `tool-gateway` | proposed | a second per-tool authz architecture (two-token OAuth 2.1) on the same tools |
| 060 | [OpenBao secrets plane](060-openbao-secrets/README.md) | `secrets` | proposed | the dispatcher's hand-rolled mint/revoke becomes dynamic secrets under one mount |
| 070 | [Dapr Workflow + Dapr Agents](070-dapr-durable-agents/README.md) | `orchestration` | proposed | the coding agent's control loop becomes durable activities, with grants (never tokens) as the durable artifact |
| 080 | [Arize Phoenix trace backend](080-phoenix-observability/README.md) | `observability` | proposed | swap Langfuse for Phoenix behind the same collector, then turn traces into an eval harness (datasets + experiments) |
| 090 | [Attested actor tokens](090-attested-actor-token/README.md) | `identity` (the join of its halves) | proposed | the 8693 exchange's actor leg authenticated by attested workload identity (040's SVID or 070's Sentry JWT) instead of a client secret — the `act` claim stops being assertable |

**The compounding demo** is 010 → 030 → 070: token exchange gives you narrow per-hop credentials, RAR gives you typed per-transaction grants, and Dapr makes the grant durable while tokens stay ephemeral at the activity boundary. Each step reuses everything before it. 090 slots into that chain rather than extending it: with 040 or 070 present, the exchange's actor leg becomes attested, so the chain's `act` claims are cryptographically bound to workloads end to end. 020 is the same compounding run on the other leg — it composes with 010/030/070 because Floci's Cognito and STS sit at the same seam Keycloak does.

## Writing one

Copy [`_template/README.md`](_template/README.md). An extension directory is self-contained: its README (guide, same voice as the lab guides), its manifests, and an `ext.mk` the root Makefile includes, exposing `make ext-<name>` / `make ext-<name>-verify` / `make ext-<name>-down`. The verify target follows the repo rule: **every claim gets a positive control** — a "blocked" result with no control beside it is indistinguishable from a control that enforces nothing.
