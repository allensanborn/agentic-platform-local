# Lab 3 — Tools behind a gateway

> **The control point: the agent gateway owns which tools an agent can see and call.**

Local port of the workshop's `500-agent-tools-mcp`. **No substitution at all** — agentgateway is the workshop's own choice and it runs here unmodified.

## Why this lab exists

In lab 1 the agent *imported* its tools. That means the agent's capabilities are a property of its image: adding a tool is a rebuild, and every caller of that agent gets every tool it holds.

This lab moves the tools to an MCP server behind a gateway, and the agent discovers them at runtime. Nothing about the agent's *security* changes yet — that is lab 4. What changes is that a place now exists where a decision about tools could be made. Lab 4 is the argument for why the network hop is worth paying for.

## What you run

`make up-all` covers this lab. On an already-running cluster, the three pieces are:

```bash
make agentgateway    # CRD chart FIRST, then the controller — see the trap below
make images          # builds and side-loads mcp-server:local
make deploy          # the MCP server, the Gateway, the AgentgatewayBackend, the HTTPRoute
                     # (and lab 4's authz, which deploy applies on purpose)
kubectl rollout restart deploy/customer-agent
```

Then start a **new** chat session and watch the agent log for `Discovered N MCP tools`.

> **This is not optional plumbing.** The agent's ConfigMap points `MCP_SERVER_URLS` at `mcp-gateway.agentgateway-system.svc.cluster.local`, so an agent without this lab starts cleanly, connects to nothing, and discovers **zero tools**. That is why `make up` (labs 0-1) no longer produces a working chat on its own: it does not install agentgateway. Use `make up-all`.

> **The trap:** install `agentgateway-crds` before `agentgateway`. The other order crashloops the controller on `Unauthorized`, because its ClusterRole is generated against types that do not exist yet. [RUNBOOK.md](../../docs/RUNBOOK.md#labs-3-and-4--how-they-come-up-and-the-two-traps-in-the-ordering) has the second trap (the Gateway naming collision) and the cross-lab dependency on lab 5.

## What to look at

**Three objects put an MCP server behind a gateway, and none of them is AWS-specific:**

1. a Service marked `appProtocol: agentgateway.dev/mcp`, which is how the gateway knows this backend speaks MCP rather than plain HTTP
2. an `AgentgatewayBackend` naming it as an MCP target over StreamableHTTP
3. a vanilla Gateway-API `HTTPRoute` pointing at that backend

**What is deliberately *not* in `k8s.yaml`: any authorization.** Lab 4 adds it as two more objects, without touching the agent or the tools. That separation is the whole argument for routing tool calls through a gateway.

**Least privilege became real, not decorative.** The orders `initContainer` and volume moved from the agent to the MCP server. Check it directly:

```bash
kubectl exec deploy/customer-agent -- ls /data
# No such file or directory
```

This is exactly where the workshop's agent ServiceAccount loses its DynamoDB IAM role — the same move, with the IAM removed because there was never any IAM.

**`tools-lab1-superseded.py`** is kept in this directory on purpose. It is the lab-1 tool implementation, and it is where the DynamoDB → SQLite substitution is actually visible.

## What should surprise you

**The agent gained capabilities with no rebuild.** It stopped importing `lookup_order` and started calling `list_tools` at session start. It picked up `check_inventory` and `initiate_return` from the server's advertisement, and used `check_inventory` correctly on the first question that needed it. No new image, no new code path.

**Discovery happens on the first chat message of a session, not at pod startup.** Strands binds auth once, at transport connect, and binds each discovered tool to the client that listed it.

This has a consequence that will waste your time in lab 4 if you do not know it now: **a policy change needs a new conversation.** A reused `session_id` shows a cached tool list and looks exactly like a policy that failed to apply.

**Do not name the Gateway after its Helm release.** The chart owns a Deployment named `agentgateway` in `agentgateway-system`, and the Gateway controller creates a data-plane Deployment named after the Gateway. The collision is an immutable-selector error that retries forever **while the Gateway still reports `Programmed=True`**. The manifest names it `mcp-gateway` and says so in a comment.

## What the substitution costs

| | Workshop | Here |
|---|---|---|
| Tool gateway | agentgateway | **the same**, unmodified |

**Preserved:** everything. There is no AWS in this lab to remove.

**Cost:** tool calls now cross a network. Lab 4 is what that buys.

**Also cost, honestly:** the agentgateway Helm chart name and version are **not recorded anywhere in this repo or its git history**. That is the one genuinely unreproducible step in the build, and it is why this lab has no `make` target.

## Go deeper

- [`modules/700-authz/README.md`](../700-authz/README.md) — what the gateway hop buys
- [TALK.md, Part 4](../../docs/TALK.md#part-4--labs-3-and-4-tools-behind-a-gateway-and-the-cheapest-lab-in-the-workshop)
- [RUNBOOK.md, Lab 3](../../docs/RUNBOOK.md#lab-3--tools-discovered-at-runtime)

**Next:** [Lab 4 — authorization](../700-authz/README.md).
