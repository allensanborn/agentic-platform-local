"""The Order specialist — an A2A server that is itself an MCP client.

Local port of the workshop's `600-multi-agent-a2a/a2a-agents/order_agent.py`.

This is the pod where both hops meet. It RECEIVES an A2A call carrying the caller's bearer and
it MAKES an MCP call that must carry the same bearer, or the persona dies here and every
downstream authorization decision is made about the wrong principal.

Reading the inbound token needs no custom plumbing: the a2a default context builder puts the
request headers on `ServerCallContext.state['headers']`, so the executor can read
`authorization` straight off it.

Changes from the workshop original:
  - logs the discovered MCP tool list (and the persona it decoded from the token) on every
    request. That log line is the deterministic proof that identity survived BOTH hops: the
    list differs by persona, and the persona came in over A2A. It is also the only part of the
    verification that does not depend on the local model behaving.
  - the agent card advertises its gateway URL rather than its Service URL (the workshop leaves
    a TODO there); nothing consults the card here, but a wrong card is a trap for the next
    reader.
"""

import base64
import json
import os

from strands import Agent
from strands.models.openai import OpenAIModel
from strands.tools.mcp import MCPClient
from mcp.client.streamable_http import streamablehttp_client
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import InMemoryTaskStore
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.apps import A2AStarletteApplication
from a2a.types import AgentCapabilities, AgentCard, AgentSkill
from a2a.utils.message import new_agent_text_message
import uvicorn

model_base_url = os.environ.get("MODEL_BASE_URL", "http://localhost:4000/v1")
mcp_server_url = os.environ.get(
    "MCP_SERVER_URL", "http://mcp-server.default.svc.cluster.local:8080/mcp"
)
self_url = os.environ.get(
    "SELF_URL", "http://mcp-gateway.agentgateway-system.svc.cluster.local/order-agent"
)

model = OpenAIModel(
    client_args={
        "base_url": model_base_url,
        "api_key": os.environ.get("MODEL_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("MODEL_ID", "local-smart"),
    params={
        "max_tokens": int(os.environ.get("MODEL_MAX_TOKENS", "4096")),
        "temperature": 0.3,
    },
)

SYSTEM_PROMPT = (
    "You handle order inquiries. Use lookup_order to check status and "
    "initiate_return for returns. Be concise."
)


def _incoming_bearer(context: RequestContext) -> str | None:
    """Read the Authorization bearer the orchestrator forwarded on the A2A call.

    The a2a default context builder populates `ServerCallContext.state['headers']` with the
    incoming request headers, so we read the token there — no custom context builder needed.
    Forwarding it to the MCP client is what lets agentgateway enforce per-tool persona authz
    downstream.
    """
    call_ctx = getattr(context, "call_context", None)
    headers = (call_ctx.state.get("headers") if call_ctx else None) or {}
    auth = headers.get("authorization") or headers.get("Authorization")
    if auth and auth.lower().startswith("bearer "):
        return auth[7:]
    return None


def _persona(token: str | None) -> str:
    """Decode the persona from the JWT for LOGGING ONLY — signature not verified.

    Nothing here trusts this value; agentgateway is what verifies the token. This exists so
    the log line can say which persona a tool list belonged to.
    """
    if not token:
        return "anonymous"
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
        groups = [g for g in (claims.get("groups") or []) if g]
        who = claims.get("preferred_username") or claims.get("sub", "?")
        return f"{who}{'/' + groups[0] if groups else ''}"
    except Exception:
        return "undecodable"


def _unwrap(exc: BaseException, depth: int = 0) -> str:
    """Flatten an ExceptionGroup / __cause__ chain down to the exception that actually says why.

    Strands' MCPClient runs its transport under anyio, so a plain HTTP 401 arrives wrapped as
    `MCPClientInitializationError: ... unhandled errors in a TaskGroup (1 sub-exception)`. The
    status code is two layers down, in `.exceptions[0]`. Same unwrapping the infra suite's
    tests/conftest.py `explain()` does, for the same reason: the outer message is useless and
    the inner one is the answer.
    """
    if depth > 5:
        return f"{type(exc).__name__}: {exc}"
    subs = getattr(exc, "exceptions", None)
    if subs:
        return " | ".join(_unwrap(s, depth + 1) for s in subs)
    cause = exc.__cause__ or exc.__context__
    if cause is not None and type(cause) is not type(exc):
        return f"{type(exc).__name__}: {exc} <- {_unwrap(cause, depth + 1)}"
    return f"{type(exc).__name__}: {exc}"


class OrderAgentExecutor(AgentExecutor):
    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        query = context.get_user_input()

        # A request-scoped MCP client carrying the forwarded persona token. Strands' MCPClient
        # binds auth at connect and binds each tool to the client that listed it, so a
        # per-request client is required to carry per-user identity — the same constraint that
        # forced the 200 agent's session cache. agentgateway then authorizes each tool call by
        # the persona's `groups` claim (module 700).
        token = _incoming_bearer(context)
        headers = {"Authorization": f"Bearer {token}"} if token else None

        # Log the persona BEFORE connecting, not only after. This line used to live under
        # list_tools_sync(), so a failed MCP connect printed nothing at all and the only evidence
        # left was `unhandled errors in a TaskGroup` — which names neither the persona, the
        # token, nor the status code. That is what made beads llm-wiki-661.20 expensive to find.
        # Printed here, `token=no` is visible the instant it happens.
        print(
            f"[a2a-in] persona={_persona(token)} token={'yes' if token else 'no'} "
            f"mcp={mcp_server_url}",
            flush=True,
        )

        mcp_client = MCPClient(lambda: streamablehttp_client(mcp_server_url, headers=headers))
        try:
            mcp_client.__enter__()
        except Exception as exc:  # noqa: BLE001 — the SUB-exception is the whole diagnosis
            raise RuntimeError(
                f"MCP connect to {mcp_server_url} failed "
                f"(persona={_persona(token)} token={'yes' if token else 'no'}): {_unwrap(exc)}"
            ) from exc
        try:
            tools = mcp_client.list_tools_sync()
            print(
                f"[a2a-in] persona={_persona(token)} token={'yes' if token else 'no'} "
                f"mcp_tools={[t.tool_name for t in tools]} query={query!r}",
                flush=True,
            )
            agent = Agent(model=model, system_prompt=SYSTEM_PROMPT, tools=tools)
            reply = str(agent(query))
        finally:
            mcp_client.__exit__(None, None, None)
        await event_queue.enqueue_event(new_agent_text_message(reply))

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        # Strands Agent has no in-flight cancellation hook, so this is a no-op.
        pass


agent_card = AgentCard(
    name="Order Agent",
    description="Handles order status lookups and return processing",
    url=self_url,
    version="1.0.0",
    default_input_modes=["text"],
    default_output_modes=["text"],
    capabilities=AgentCapabilities(streaming=False),
    skills=[
        AgentSkill(
            id="orders",
            name="Order Management",
            description="Look up orders, track shipments, process returns",
            tags=["orders", "returns", "tracking"],
        )
    ],
)

app = A2AStarletteApplication(
    agent_card=agent_card,
    http_handler=DefaultRequestHandler(
        agent_executor=OrderAgentExecutor(), task_store=InMemoryTaskStore()
    ),
)

if __name__ == "__main__":
    uvicorn.run(app.build(), host="0.0.0.0", port=int(os.environ.get("PORT", "8081")))
