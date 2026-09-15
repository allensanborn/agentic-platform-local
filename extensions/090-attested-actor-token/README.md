# 090 — Attested actor tokens: the delegation chain's actor leg stops being assertable

**Seam:** `identity` (the *join* of its two halves — 010 owns the user half, 040/070 own the workload half; this extension is the seam where they meet) · **Status:** proposed
**Base required:** labs 0-4
**Requires extensions:** 010 (the 8693 exchange must exist). Plus **one attested-JWT issuer at the workload half:** 040 (SPIRE JWT-SVIDs) *or* 070 (Dapr ≥1.16 — Sentry issues SPIFFE-bound JWTs with OIDC discovery). Composes with 030 (its subset rule is the authorization-details mirror of what this does for identity).
**Alternative to:** none — this hardens 010, it does not replace it.

## What this demonstrates

In 010, the gateway authenticates to Keycloak's exchange endpoint the way every OAuth client does: with a **client secret** — a possessed, copyable string. The `act` claim in the exchanged token therefore *asserts* the actor; anything holding that secret can claim to be the gateway. The workload half of the seam (040/070) already proves cryptographically *which workload is running* — but that proof stops at the transport layer and never enters the delegation chain.

This extension joins them: the actor leg of the RFC 8693 exchange is authenticated by **attested workload identity** — a JWT-SVID (040) or Sentry-issued JWT (070) presented as the `actor_token`, or the workload's X.509-SVID as the mTLS client certificate on the exchange call (RFC 8705). Either way, the exchanged token's `act` claim now names an identity that was *attested at mint time*, not asserted by secret possession.

The control point: the delegation chain itself. `sub` is the user (who consented), `act` is the workload (proved by the platform, not by a string it holds), `authorization_details` is the intent (030, if installed). Every leg of "who authorized this action" is now backed by the layer actually competent to prove it — and there is no copyable credential left on the actor leg to steal.

This is not a novel design — that's the point. Red Hat's Kagenti wiring (2026-06) ships the identical shape (Keycloak as STS, SPIFFE SVIDs authenticating the workload leg, nested `act` delegation, and a "permission intersection" rule — agents can only reduce user permissions, never expand them — which is 030's ceiling and ThunderID issue #5153's subset-only rule arrived at by a third team independently). IETF **WIMSE** is standardizing the same join (token-exchange profiles for SPIFFE-identified services; `draft-ietf-oauth-spiffe-client-auth` for the client-auth leg). What this extension adds is the workshop's own discipline: run it on the base's real personas and tools, with positive controls.

## The substitution

| | Base + 010 | This extension |
|---|---|---|
| actor authentication at the STS | client secret (possessed, copyable) | attested workload identity (SVID / Sentry JWT — nothing to copy) |
| `act` claim provenance | asserted by whoever holds the secret | bound to node+workload attestation at mint time |

Preserved: agent code (still zero change), 010's narrow per-tool downstream tokens, lab-4 policies, both personas. Cost: Keycloak must trust the workload issuer (the spike below), plus whichever of 040/070 is installed.

## The spike question (answer before building)

**Which trust mechanism does Keycloak actually support for the workload leg?** Three candidates, in preference order: (a) `actor_token` with `actor_token_type=jwt` validated against the issuer's JWKS — SPIRE's OIDC-discovery provider or Dapr Sentry's `/jwks.json` registered as a trusted issuer; (b) RFC 8705 mTLS client auth with the X.509-SVID as client cert (Red Hat's listed mechanism); (c) Keycloak identity brokering / external-to-internal exchange. The Red Hat post proves *some* Keycloak path exists in production shape; pin down which one on our Keycloak version before writing a line of config. This is the extension's honest unknown — file the answer back into this README.

## Plan

1. 010 up and verified; capture the exchange request/response and the before-trace (the `act` claim minted via client secret).
2. Stand up the workload issuer: 040's SPIRE with the OIDC discovery provider, or 070's Dapr with `dapr.io/sentry-request-jwt-audiences` — whichever is already installed; do not install both for this.
3. Resolve the spike: register the issuer with Keycloak; verify with a bare `curl` exchange presenting the workload JWT before touching the gateway (010's own step-2 discipline).
4. Rewire 010's `backendAuth.oauthTokenExchange` (or the ext-proc hop) to present the workload credential on the exchange.
5. Surface it: the trace's `act` claim now carries the SPIFFE ID — assert `spiffe://` appears in the decoded token in the test, nested under the user's `sub`.

## Verify

- decoded exchanged token: `sub` = persona, `act.sub` = the workload's SPIFFE identity, scope/TTL unchanged from 010
- **positive control (the theft that used to work):** exfiltrate the base client secret into a rogue pod and run the exchange — succeeds under plain 010, refused under 090 (the rogue pod cannot attest as the gateway)
- a workload JWT minted for a *different* workload (wrong SPIFFE path) is refused by the STS
- 040 in place of 070 (or vice versa) passes the same tests unchanged — the join depends on the seam contract (an attested JWT with OIDC discovery), not the provider

## Grounding

wiki: `agent-identity-delegation-vs-attestation` (the comparison this extension operationalizes — delegation-down and attestation-up meeting at 8693), `agent-authorization-stack-2026` (Dapr 1.16 Sentry-as-OIDC-issuer is "the bridge many assume is missing"), `dapr-diagrid-service-identity`, `wso2-thunder` (issue #5153's subset-only delegation), `redhat-kagenti-spiffe-token-exchange` (the shipped prior art). Standards: RFC 8693, RFC 8705, draft-ietf-oauth-spiffe-client-auth, the WIMSE token-exchange profiles. Note 040's plan already gestures at half of this (JWT-SVID as `subject_token` — the workload as *principal*); 090 is the other, stronger half: the workload as *attested actor for a user*.
