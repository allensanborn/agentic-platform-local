# 010 — Token exchange (RFC 8693)

**Seam:** `identity` · **Status:** proposed
**Base required:** labs 0-4 (`make up-all` through `identity`; agentgateway routing MCP with JWT authn)
**Requires extensions:** none
**Alternative to:** none — this *extends* the base Keycloak, it does not replace it

## What this demonstrates

The base ships the user's own bearer token all the way to the tool boundary. This extension inserts the exchange the workshop's own stack supports but never uses: agentgateway's `backendAuth.oauthTokenExchange` — called out in [TALK.md](../../docs/TALK.md) as "the hard part that would need an STS token vault, used by no lab." The gateway trades the inbound persona token for a **narrower, shorter-lived downstream token scoped to the one tool being called**, and the `actor_token` delegation chain (user → agent → tool) becomes visible in the Langfuse trace.

The control point: the gateway owns the blast radius of a leaked credential. A token stolen from the MCP hop is now scoped to one tool and minutes of validity, not the user's whole session.

## The substitution

| | Base | This extension |
|---|---|---|
| downstream credential | the user's bearer token, forwarded intact | a per-tool token minted by Keycloak's 8693 endpoint at the gateway |

Preserved: agent code (zero change — it still just carries its session token), the lab-4 policies, both personas. Cost: Keycloak ≥ 26.2 (official 8693 support) and one more hop per tool call.

## Plan

1. Base up; `make test` green; capture a lab-4 trace as the before.
2. Enable token-exchange on the `anycompany` realm; verify with a bare `curl` exchange (`grant_type=token-exchange`) before touching the gateway.
3. Configure `backendAuth.oauthTokenExchange` on the MCP backend; confirm `tools/call` still works for `sam` and `ana`.
4. Make the chain observable: log/propagate the exchanged token's `act` claim into the trace.
5. Verify + controls (below).

## Verify

- exchanged token presented at the MCP server has the narrow scope and short TTL (decode it in the test, assert claims)
- **positive control:** replaying the *user's* original token directly against the MCP server still succeeds before the extension and is rejected after it
- lab 4's behavior is unchanged from the outside: `sam`/`ana` tool lists identical to base

## Grounding

wiki: `agent-authorization-stack-2026` (8693 is commodity: Keycloak 26.2 official, 26.5 identity chaining; agentgateway uses it as default grant), `oauth2`, log 2026-08-28.
