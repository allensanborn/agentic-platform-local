# Module 600 — multi-agent (A2A), the third hop

> **Status: written, NOT yet verified.** The Docker engine on the host was hung while this was
> built, so nothing here has been built, deployed, or run. See "Verification status" at the
> bottom for exactly what was and was not checked.

Local port of the workshop's `600-multi-agent-a2a`. It adds a hop the previous labs did not
have — agent to agent — and it needs **no new infrastructure**: the mcp-gateway, Keycloak realm,
MCP server and model gateway from labs 0-4 are all reused as they stand.

```
UI -> orchestrator -> [agentgateway A2A] -> order-agent -> [agentgateway MCP] -> mcp-server
                                         -> product-agent
```

## The two things worth reading the code for

**1. A2A and MCP have opposite identity models, in the same process.**

Strands' `MCPClient` binds its `Authorization` header **once**, when the transport connects, and
binds every discovered tool to the client that listed it. That single fact is why
`modules/200-agent/customer-agent` builds a whole agent per session — a shared client cannot
carry a per-user token.

`A2AClient.send_message()` takes `http_kwargs` on **every call**. There is no client-lifetime
auth binding at all; one client can serve any number of personas. So the orchestrator's
session cache exists only to label traces, while the customer agent's identical-looking cache is
load-bearing for authorization.

The token reaches the `@tool` functions through a `contextvars.ContextVar`, not a parameter:
`server.py` sets it per request, Strands propagates context into tool execution, and
`ask_order_agent` reads it. Deliberately invisible to the model — a token the model can see is a
token the model can omit, garble, or be talked into replacing.

On the receiving side, `order_agent.py` reads the inbound bearer off
`RequestContext.call_context.state['headers']['authorization']`, which the a2a SDK's **default**
context builder populates. No custom builder needed.

**2. The hop is authenticated but not authorized.** That is [ADR
0011](../../docs/adr/0011-a2a-is-the-least-governed-hop.md), and module
[800-a2a-authz](../800-a2a-authz/) is where the policy lives.

## What differs from the workshop

| Thing | Workshop | Here | Why |
|---|---|---|---|
| `search_products` backing store | Milvus + fastembed vector search | SQLite **FTS5** over the workshop's own 13-row catalog | Milvus is a multi-pod stateful service and fastembed bakes a ~90 MB model into the image. Neither affects what this module teaches, and together they cost more than everything else here. Same tool name, docstring and return shape; lexical instead of semantic matching. |
| Gateway name | `agentgateway` | `mcp-gateway` | The Helm chart already owns a Deployment named `agentgateway`; colliding gives an immutable-selector error while the Gateway still reports `Programmed=True`. Same note as `modules/500-mcp/mcp-server/k8s.yaml`. |
| Identity provider | Cognito, `cognito:groups` | Keycloak, `groups` | Same one-string substitution lab 4 made. |
| Tracing | `langfuse` client + `@observe` | `opentelemetry-instrument` -> OTel collector -> Langfuse | Matches every other agent in this repo (ADR 0008). |
| Images | ECR, `imagePullPolicy: Always` | built locally, `k3d image import`, `Never` | No registry. |
| Agent card `url` | the Service URL (workshop leaves a TODO) | the gateway URL | A card that advertises the bypass path is a trap for the next reader. |
| Order-agent logging | none | logs persona + discovered MCP tool list per request | It is the deterministic proof that identity crossed both hops, and the only verification that does not depend on the local model. |

## Running it

```bash
make a2a               # build 3 images, deploy, apply the module-800 authn policy
make a2a-forward       # in another shell: gateway :8081, keycloak :8085,
                       #                   orchestrator :8083, order-agent DIRECT :8181
```

Then, cheapest-and-most-certain first:

```bash
make a2a-verify        # the authorization matrix at the A2A hop. No model involved.
make a2a-hops          # persona propagation across BOTH hops. No orchestrator model involved.
make a2a-bypass        # the gate is only a gate if it is the only path
make a2a-ask USER_NAME=sam Q="Where is my order ORD-1001?"    # the whole chain, model and all
```

`a2a-hops` is the one to trust. It sends A2A `message/send` straight at the order-agent as `sam`
and as `ana`, then reads the tool list the order-agent logged for each:

```
sam (support-associate)  ->  mcp_tools=['lookup_order', 'initiate_return']
ana (sales-analyst)      ->  mcp_tools=['lookup_order']
```

Those lists are produced by agentgateway from the token, and the token only reached the MCP hop
by surviving the A2A hop. If identity died in the middle, both personas would see the same list —
or none.

## A warning about the router

The orchestrator's job is pure routing, and `qwen3:8b` is weak at exactly that: it likes to
answer from its own knowledge instead of delegating, despite a system prompt that forbids it in
three separate sentences (ADR 0003 and ADR 0007 are the background). If `make a2a-ask` produces
an answer with no `ask_order_agent` tool call in the stream, that is the **model**, not the hop.
`make a2a-hops` removes the model from the path precisely so the two can be told apart, and
`MODEL_ID: remote-smart` on the `a2a-config` ConfigMap swaps in the hosted model without touching
an image.

## Files

| File | What |
|---|---|
| `a2a-agents/orchestrator.py` | routing agent; specialists exposed as Strands `@tool`s; per-call token attach |
| `a2a-agents/server.py` | FastAPI + SSE wrapper; same wire contract as the lab-1 agent, so the existing chat UI can drive it |
| `a2a-agents/order_agent.py` | A2A server **and** MCP client — the pod where both hops meet |
| `a2a-agents/product_agent.py` | A2A server with an in-process tool and no gateway in front of it |
| `a2a-agents/k8s-specialists.yaml` | both specialists, the `a2a` AgentgatewayBackends, the two HTTPRoutes |
| `a2a-agents/k8s-orchestrator.yaml` | the orchestrator |
| `a2a-probe.py` | stdlib-only A2A JSON-RPC client — the model-free control |
| `verify.sh` / `hops.sh` / `ask.sh` | the three verifications, coarsest-to-finest |

## Verification status

Checked offline, with no cluster: Python and Bash syntax; YAML parses; and every
`AgentgatewayPolicy` / `AgentgatewayBackend` document JSON-schema-validated against the
agentgateway-crds **1.4.1** schemas, including a check that no field would be silently pruned.

Not checked, because the Docker engine was hung: image builds, deployment, routing through the
`a2a` backend type, the 401, persona propagation, and every command in the "Running it" section
above.
