# Lab 4 — Deny-by-default, per tool

> **The control point: the gateway decides which tools a persona may even see.**

Local port of the workshop's `700-agent-authorization`. This is the **shallowest substitution in the entire project and the highest-value lab in the workshop** — the complete Cognito coupling turned out to be two strings and one claim name.

## Why this lab exists

Lab 3 put a gateway between the agent and its tools and then made no decisions with it. This is where the decision gets made, and where the network hop lab 3 paid for earns its cost.

The result is one agent, one image, one deployment, serving two personas with different capabilities:

```
sam (support-associate)  ->  Discovered 2 MCP tools: ['lookup_order', 'initiate_return']
ana (sales-analyst)      ->  Discovered 1 MCP tools: ['lookup_order']
no token                 ->  HTTP 401 at the gateway
```

## What you run

Like lab 3, this has **no Makefile target**. `make identity` (Keycloak plus the `anycompany` realm) must already have run; `up-all` includes it.

```bash
kubectl apply -f modules/700-authz/policies/step3-differentiate.yaml
kubectl rollout restart deploy/customer-agent
```

Verify with the probe, in a **new session** each time:

```bash
make sandbox-forward     # needs keycloak :8085 and mcp-gateway :8081
cd modules/900-sandbox && . code-executor-mcp/.venv/bin/activate
python probe.py --url http://127.0.0.1:8081/mcp --user sam --tools-only
python probe.py --url http://127.0.0.1:8081/mcp --user ana --tools-only
```

## The three-step walk

The lab is designed to be run as three edits to **`matchExpressions` alone** — nothing else in the file changes:

| Step | Expression | Effect |
|---|---|---|
| 1 | `'false'` | deny everything |
| 2 | `'mcp.tool.name == "lookup_order"'` | one tool, everyone |
| 3 | the persona-gated rule | differentiated |

Run all three. Step 1 is not a formality; see below.

## What to look at

**The entire Cognito substitution**, in one row:

| | Workshop | Here |
|---|---|---|
| Authorization expression | `jwt["cognito:groups"]` | `jwt["groups"]` |

Plus the issuer URL and the JWKS host and path. That is the complete coupling to Amazon Cognito in this workshop, and it is why the coupling analysis that opened this project ranked Cognito as shallow and was right.

**`mode: Strict` on the JWT provider.** No token is a 401, not an anonymous pass-through.

**The `keycloak-jwks` `AgentgatewayBackend`.** agentgateway will not take a bare JWKS URL — the endpoint has to be a backend it can route to. In the workshop this fronts Cognito over TLS on 443; here it is an in-cluster plaintext hop, which is the one thing the substitution costs.

**The two policies target different things**, and that is not incidental. `mcp-authn` targets the **Gateway** — authentication applies to everything arriving. `mcp-tool-authz` targets the **`AgentgatewayBackend`** — authorization is a property of the tool surface being protected.

## Three properties worth landing separately

**An `Allow` list that matches nothing denies everything.** Deny-by-default engages the moment any rule exists, so step 1 (`matchExpressions: ['false']`) is a real, observable state rather than a no-op. Run it and watch every tool disappear.

**`check_inventory` is not denied — it is never allowed.** There is no rule about it anywhere in the file. That is what deny-by-default *means*, and it is a materially different sentence from "there is a deny rule for it." Nothing has to be enumerated to be blocked.

**The two failure modes differ in a way that matters specifically for agents.**

| Situation | What happens |
|---|---|
| missing or invalid token | a loud **401 at the gateway**, before any tool logic runs |
| valid token, no right | the tool **vanishes from `tools/list`** |

The second one is the interesting one. The agent never discovers the capability, so the model does not *refuse* — it genuinely cannot see the thing. **There is no capability to be talked into using**, which is a strictly stronger property than a refusal the model has been trained to produce. Prompt injection has nothing to work with.

Note also the deliberate asymmetry: support-associate has `initiate_return`, sales-analyst has `run_python` (added in lab 5), and **neither persona is a superset of the other**. That prevents "admin vs user" from being the only mental model you leave with.

## What should surprise you

**How little of this is about the agent.** The agent code does not change in this lab at all. The one piece of structure that makes it possible was built in lab 3: the agent is constructed **per session**, so it can carry the caller's bearer token to the MCP transport. That was a deliberate down-payment — building it in lab 3 meant lab 4 added a parameter instead of forcing a redesign.

**A policy change with no visible effect is probably a cached session.** Discovery happens on the first chat message of a session. Start a new conversation before concluding the policy did not apply.

## What the substitution costs

| | Workshop | Here |
|---|---|---|
| Identity | Amazon Cognito | Keycloak, `anycompany` realm |

**Preserved:** everything. Issuer, JWKS, one claim name.

**Cost:** one in-cluster plaintext JWKS hop, where the workshop fronts Cognito over TLS on 443. On a laptop, with the JWKS endpoint inside the same cluster, that is the trade.

## Go deeper

- [TALK.md, Part 4](../../docs/TALK.md#lab-4--cognito--keycloak-two-strings-and-one-claim-name)
- [RUNBOOK.md, Lab 4](../../docs/RUNBOOK.md#lab-4--deny-by-default-per-tool)
- [`platform/identity/realm-anycompany.json`](../../platform/identity/realm-anycompany.json) — where `sam` and `ana` come from

**Next:** [Lab 5 — sandboxed code execution](../900-sandbox/README.md), where the persona split gets a much sharper demonstration.
