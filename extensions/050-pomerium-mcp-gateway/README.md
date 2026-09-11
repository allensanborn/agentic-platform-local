# 050 — Pomerium as the MCP gateway

**Seam:** `tool-gateway` · **Status:** proposed
**Base required:** labs 0-4
**Requires extensions:** none
**Alternative to:** the base's agentgateway (same seam — pick one per cluster, or run both against the same MCP server for the comparison demo)

## What this demonstrates

Lab 3's design decision — the agent *discovers* tools rather than importing them — makes the tool gateway itself swappable, and this extension proves it by putting a second, differently-shaped gateway on the same seam: **Pomerium**, the Envoy-based identity-aware proxy now repositioning as an AI/MCP gateway with a **credential-isolating two-token OAuth 2.1 design**. Same MCP server, same personas, same tools — a different per-tool authorization architecture.

The teachable comparison, which neither gateway shows alone: agentgateway expresses authz as **CRD policy over the MCP surface** (tools vanish from `tools/list`); Pomerium expresses it as **identity-aware routing with the upstream credential held by the proxy** — the agent never touches the token that reaches the tool. Two answers to "where does the credential live," side by side.

## The substitution

| | Base | This extension |
|---|---|---|
| `tool-gateway` | agentgateway (MCP proxy, AgentgatewayPolicy CRDs) | Pomerium (OAuth 2.1 two-token, policy-as-routes) |

Preserved: the MCP server, the tools, Keycloak, the persona semantics. Cost: re-expressing lab 4's persona matrix in Pomerium policy, and validating how faithfully MCP passes through (spike: `tools/list` filtering — does Pomerium hide or refuse?).

## Plan

1. Base up with the lab-4 matrix verified — that matrix is the acceptance test for the port.
2. Pomerium in front of the MCP server, Keycloak as its IdP; route the agent through it.
3. Re-express the matrix; document what maps 1:1 and what has no equivalent, in both directions.
4. Verify + controls.

## Verify

- the persona matrix reproduces exactly (sam: 2 tools, ana: lab-3 set; no token: refused)
- the credential-isolation claim demonstrated, not asserted: dump the agent-side environment/headers and show the upstream credential is absent; **positive control:** on the agentgateway leg, show where the bearer token *does* transit
- `check_inventory` remains invisible-or-refused (note *which* — the difference is the finding)

## Grounding

wiki: `pomerium` (ingested 2026-09-11 — the two-token MCP design), `zero-trust`, `agentgateway`, log 2026-09-11.
