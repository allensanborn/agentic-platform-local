# 010 — Token exchange (RFC 8693)

**Seam:** `identity` · **Status:** blocked (upstream) — see **Where this stands** below
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

## Where this stands (2026-09-21)

**Steps 1-2 done and verified.** The base's Keycloak was bumped 26.0 → 26.2 (`platform/identity/keycloak.yaml`) — standard token exchange stopped being a preview feature in 26.2, and this repo's own discipline about version pairing (TALK.md) says that's worth landing as its own change rather than fighting a preview-feature flag dance. Verified with a positive control first: lab 4's exact persona matrix (`sam`: 2 tools, `ana`: 1 tool, no-token: 401) reproduced identically on 26.2 before touching anything else.

The realm (`platform/identity/realm-anycompany.json`) gained a confidential `anycompany-agentgateway` client with `standard.token.exchange.enabled`, an audience mapper on `anycompany-agent` (Keycloak's standard exchange requires the requesting client to already be in the subject token's `aud` claim — passing an `audience` request parameter alone does not satisfy this), and — the one non-obvious finding — **a `groups` mapper had to be duplicated onto the new client**, because Keycloak's exchange does not carry the subject client's claims forward by default. Without it, the exchanged token silently drops the `groups` claim lab 4's per-tool authz reads, which would have been a subtle, delayed-failure bug rather than a loud one. Verified end-to-end with a bare `curl` RFC 8693 exchange (this extension's plan step 2): `sam`'s exchanged token carries `groups: ['support-associate']`, `azp: anycompany-agentgateway`, and (correctly, per RFC 8693 semantics with no `actor_token` supplied) no `act` claim — extension 090 is where that leg gets built.

**Step 3 (wiring `AgentgatewayPolicy`'s `backend.auth.oauthTokenExchange`) is blocked.** The manifest is in `policies/token-exchange.yaml`, schema-valid (`kubectl explain` against the live v1.5.0 CRDs; policy reports `Accepted: True`, `Attached: True`), and was tried in multiple field-shape variations — `backendRef` + `ReferenceGrant` vs the `url` shortcut, explicit vs defaulted `subjectToken`/`location`, with and without `requestedTokenType` (a recent agentgateway changelog note flags exactly this field as needing to be omitted for some authorization servers to get RFC 8693 default behavior — tried, no change). Every variant fails identically: every authenticated MCP call returns

```
{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"failed to send message: http upstream error: http request failed: invalid request"}}
```

with `duration=10ms` in the gateway's structured request log and no further detail — `RUST_LOG=debug` doesn't survive on the data-plane pod (the controller reconciles the Deployment spec and silently reverts a manual `kubectl set env` patch), and Keycloak's own access log shows nothing arriving in the same window. Ruled out independently: the base MCP flow (no exchange policy) succeeds via the identical raw-curl test harness, so this isn't a test-methodology artifact; the Keycloak-side exchange this policy is configured to drive is proven correct by the standalone curl test above. `backendAuth.oauthTokenExchange` is a very recently shipped feature (agentgateway blog, 2026-07-12, the same release — v1.5.0 — this cluster runs), which is consistent with a real rough edge rather than a config mistake on this end.

**Left in a clean state:** the broken `AgentgatewayPolicy` was removed from the live cluster (it 500s every authenticated MCP call while applied) — the demo is back to base behavior. The Keycloak 26.2 bump and realm changes stay, since they're independently correct and verified. `policies/token-exchange.yaml` stays in the repo as the documented, schema-valid attempt for whoever picks this back up — likely candidates: pin an older/newer agentgateway patch once one exists, or file upstream against `agentgateway/agentgateway` with this exact repro (base up through `identity`+`agentgateway`, apply the policy, `curl` an `initialize` call with a valid bearer).

## Grounding

wiki: `agent-authorization-stack-2026` (8693 is commodity: Keycloak 26.2 official, 26.5 identity chaining; agentgateway uses it as default grant), `oauth2`, log 2026-08-28. Upstream: [agentgateway token-exchange/jwt-assertion/Entra-OBO announcement](https://agentgateway.dev/blog/2026-07-12-agentgateway-token-exchange-jwt-assertion-entra-obo/) (v1.5.0, the version this was tried against).
