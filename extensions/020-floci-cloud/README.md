# 020 — Floci: the un-substitution

**Seam:** `identity` + `datastore` + `model` · **Status:** proposed
**Base required:** labs 0-5
**Requires extensions:** none
**Alternative to:** the base's Keycloak (`identity`) and SQLite (`datastore`) — per cluster, pick this leg or that one. Composes with 010/030/070, which depend on seam *behavior*, not on which implementation sits there.

## What this demonstrates

The repo's thesis so far is "the AWS coupling was shallow — I removed it." This extension runs the argument in reverse: **restore the workshop's verbatim upstream code paths and run them against [Floci](https://github.com/floci-io/floci)**, a local AWS emulator. Same laptop, no AWS account — but now the agent speaks boto3 to DynamoDB, agentgateway validates JWTs against a real Cognito user pool's JWKS, and the AI gateway exercises its Bedrock backend with SigV4 signing. The port proved the substitutions were clean; this proves the *originals* still fit, which is the stronger fidelity claim — and a live conformance test of Floci's emulation against picky consumers.

Three sub-steps, one per seam, each independently valuable:

1. **Cognito replaces Keycloak.** The port documented this coupling as two strings and one claim name. Point the gateway's JWKS backend at Floci Cognito's well-known endpoints, restore `cognito:groups`, and lab 4 runs the upstream policy config unmodified.
2. **DynamoDB replaces SQLite.** Un-do the port's two edits: `tools.py` back to `get_item`/scoped `Query` with boto3, `requirements.txt` gets boto3 back — endpoint-pointed at Floci. The `@tool` signature never moves, in either direction.
3. **Bedrock Runtime behind the AI gateway.** The one workshop code path the rebuild never touched: the gateway's Bedrock backend + SigV4 (creds from Floci IAM/STS). **Spike first:** what Floci's Bedrock Runtime answers with, and whether it can be backed by Ollama — that pairing is the headline if it works.

## The substitution

| | Base (the port) | This extension (the un-port) |
|---|---|---|
| `identity` | Keycloak, `anycompany` realm, `groups` claim | Floci Cognito user pool, `cognito:groups` |
| `datastore` | SQLite behind the tool contract | Floci DynamoDB, upstream `tools.py` verbatim |
| `model` | Ollama via OpenAI-compatible backend | Floci Bedrock Runtime via the gateway's Bedrock backend + SigV4 |

Preserved: everything above the seams — agent, policies, traces, sandbox. Cost: one more running system (Floci via `docker compose up`), and the spike risk on Bedrock.

## Plan

1. Base up. Floci up beside the cluster; smoke-test each service with the AWS CLI (`--endpoint-url`).
2. Seam by seam, in the order above — each lands as its own commit with its own verify, so a partial extension is still a working cluster.
3. Diff exercise for the docs: `git diff` of `tools.py` between base and extension should reproduce the port's original substitution table, inverted.

## Verify

- lab-4 persona matrix identical under Cognito (same `tools/list` per persona; 401 without a token)
- upstream `tools.py` answers the same order queries the SQLite version did (same eval set, `tests/evals`)
- a Bedrock-path model call appears in the Langfuse trace with the same span shape as the Ollama path
- **positive control:** stop Floci; every seam fails loudly and attributably (JWKS unreachable ≠ policy pass)

## Grounding

wiki: `homelab-agentic-platform-plan` (the original coupling analysis this inverts); Floci service notes (Cognito JWKS/OIDC well-known, DynamoDB Query/GSI, Bedrock Runtime, IAM/STS). Stretch: Floci's **Bedrock AgentCore** emulation would let the managed-vs-OSS control-plane comparison (AgentCore vs agentgateway) run side-by-side on one laptop.
