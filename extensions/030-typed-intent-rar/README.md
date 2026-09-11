# 030 — Typed intent (RFC 9396 Rich Authorization Requests)

**Seam:** `grant-shape` · **Status:** proposed
**Base required:** labs 0-5
**Requires extensions:** 010 (an identity seam that can mint per-use tokens — RAR details ride the exchanged token)
**Alternative to:** none — it narrows lab 4's grants, it does not replace the policy layer

## What this demonstrates

Lab 4's grants are coarse: a persona may call `initiate_return` on *any* order, forever, because the claim is a group name. This extension binds the grant to **one typed transaction**: `authorization_details: [{type: "initiate_return", order_id: "...", max_amount: ...}]`, enforced where the semantics live — at the tool boundary. The wiki's survey found essentially nobody deploys RAR publicly (0 of 19 reachable authorization servers advertised support), so a working end-to-end demo is genuinely novel, and the MCP tool signature is exactly why it is buildable here: **a tool's name plus input schema already *is* the typed transaction** RFC 9396 assumes someone will define.

Equally important is demonstrating the documented limit on the same stage: `run_python` is nominally typed and semantically open — "analyze Q1 sales" has no fields to bind. That is not an authorization problem but a containment one, **which lab 5 already is**. The two tools side by side make the boundary of the model visible: typed intent for transactions with fields, sandbox containment for open-ended work.

## The substitution

| | Base | This extension |
|---|---|---|
| grant | persona → static tool allowlist | persona + `authorization_details` → one transaction, checked field-by-field at `tools/call` |

Preserved: deny-by-default, the persona matrix, the agent (it still just calls tools). Cost: RAR enforcement is custom by specification — the resource-server half is build-your-own regardless of vendor, so this extension owns a small enforcement shim at the MCP server.

## Plan

1. Base + 010 up; before-trace captured.
2. Teach the token path to carry `authorization_details` (Keycloak custom claim or the 010 exchange response).
3. Enforcement shim at the MCP server: `initiate_return` asserts the call's arguments match the grant's fields. Reject on mismatch with a distinct error the trace can show.
4. The demo script: same persona, two calls — the granted `order_id` succeeds, a different `order_id` is refused *despite the tool being visible*. Then `run_python` with the containment narration.
5. Verify + controls.

## Verify

- granted transaction passes; same tool with off-grant fields fails with the RAR-mismatch error (not a 401, not a hidden tool — a third, distinct failure mode to put beside lab 4's two)
- **positive control:** with the shim disabled, the off-grant call succeeds — proving the refusal came from enforcement, not coincidence
- lab-4 behavior unchanged for tools without `authorization_details`

## Grounding

wiki: `agent-intent-authorization` (what RAR binds and where it stops), `durable-workflow-authorization` (the activity-signature-is-the-typed-transaction argument), `agent-authorization-stack-2026` (deployment survey; enforcement-is-custom-by-spec), log 2026-08-28 / 2026-08-31.
