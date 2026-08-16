"""The routing agent — lab 6's third hop.

Local port of the workshop's `600-multi-agent-a2a/a2a-agents/orchestrator.py`.

Two specialists are exposed to the model as ordinary Strands `@tool` functions, so from the
model's point of view delegating to another agent is indistinguishable from calling a tool.
What is different is underneath: each call is an A2A JSON-RPC request that leaves this pod,
crosses agentgateway, and lands in another agent's process.

The identity mechanic is the interesting part, and it is the opposite of MCP's. Strands'
`MCPClient` binds its Authorization header ONCE, when the transport connects, which is why
`modules/200-agent/customer-agent` has to build a whole agent per session. `A2AClient` takes
`http_kwargs` on EVERY `send_message` call, so there is no client-lifetime auth binding at
all — one client can serve many personas. Two protocols in one system with opposite identity
models.

Changes from the workshop original:
  - no `langfuse` client import; this repo traces through the OTel collector into Langfuse via
    the `opentelemetry-instrument` launcher (same as the 200 agent), so there is nothing to
    import and nothing to flush.
  - the A2A failure path returns the HTTP status as tool output instead of raising. A denied
    hop is the thing lab 8 is trying to show, and "A2A call denied: HTTP 401" in the transcript
    is the demonstration; an opaque stack trace is not.
  - model defaults to the gateway alias `local-smart`, not `nova-lite`.
"""

import asyncio
import contextvars
import os
import sys
import uuid

import httpx
from strands import Agent
from strands.models.openai import OpenAIModel
from strands.tools import tool
from a2a.client import A2AClient
from a2a.types import (
    Message,
    MessageSendParams,
    Role,
    SendMessageRequest,
    TextPart,
)

# MODEL_* point at the OpenAI-compatible model gateway (lab 0), exactly as in every other
# agent here. ORDER_AGENT_URL / PRODUCT_AGENT_URL are the A2A endpoints and are unrelated to
# the model gateway — they point at agentgateway's per-agent path prefixes.
model_base_url = os.environ.get("MODEL_BASE_URL", "http://localhost:4000/v1")
order_agent_url = os.environ.get(
    "ORDER_AGENT_URL", "http://order-agent.default.svc.cluster.local:8081"
)
product_agent_url = os.environ.get(
    "PRODUCT_AGENT_URL", "http://product-agent.default.svc.cluster.local:8082"
)

# Per-request Keycloak bearer, set by server.py before the agent runs and read inside the A2A
# tool calls. A ContextVar rather than a function argument because the @tool functions are
# invoked BY the Strands agent, not by us — Strands propagates context into tool execution, so
# the token rides along. Forwarding it on each A2A call is what lets agentgateway authenticate
# the persona on the A2A hop (module 800) and what lets the specialist propagate it onward to
# MCP.
_access_token: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "access_token", default=None
)


def _extract_text(response) -> str:
    """Pull the textual reply out of a SendMessageResponse.

    The result is either a Message (direct reply) or a Task (which carries artifacts). Both
    expose `parts` lists with TextPart entries.
    """
    result = getattr(response.root, "result", None) or response.root
    parts = list(getattr(result, "parts", None) or [])
    for artifact in getattr(result, "artifacts", None) or []:
        parts.extend(artifact.parts or [])
    texts = [getattr(p.root, "text", None) for p in parts]
    texts = [t for t in texts if t]
    return "\n".join(texts) or str(result)


async def _ask(base_url: str, query: str) -> str:
    # A2AClient wraps httpx.AsyncClient and speaks JSON-RPC 2.0.
    async with httpx.AsyncClient(timeout=180) as http:
        client = A2AClient(httpx_client=http, url=base_url)
        request = SendMessageRequest(
            id=str(uuid.uuid4()),
            params=MessageSendParams(
                message=Message(
                    message_id=str(uuid.uuid4()),
                    role=Role.user,
                    parts=[TextPart(text=query)],
                )
            ),
        )
        # THE per-call auth binding. send_message takes http_kwargs -> httpx headers, so the
        # persona is attached to this request rather than to the client.
        token = _access_token.get()
        http_kwargs = (
            {"headers": {"Authorization": f"Bearer {token}"}} if token else None
        )
        print(f"[a2a] -> {base_url} token={'yes' if token else 'no'}", flush=True)
        try:
            response = await client.send_message(request, http_kwargs=http_kwargs)
        except Exception as exc:  # noqa: BLE001 - the status code IS the lesson here
            status = getattr(exc, "status_code", None)
            if status is None:
                resp = getattr(exc, "response", None)
                status = getattr(resp, "status_code", None)
            detail = f"HTTP {status}" if status else type(exc).__name__
            print(f"[a2a] <- {base_url} DENIED/FAILED {detail}: {exc}", flush=True)
            return f"A2A call to {base_url} failed: {detail}"
        return _extract_text(response)


@tool
def ask_order_agent(query: str) -> str:
    """Route order-related queries (status, tracking, returns) to the Order Agent."""
    return asyncio.run(_ask(order_agent_url, query))


@tool
def ask_product_agent(query: str) -> str:
    """Route product questions (search, pricing, policies) to the Product Agent."""
    return asyncio.run(_ask(product_agent_url, query))


model = OpenAIModel(
    client_args={
        "base_url": model_base_url,
        "api_key": os.environ.get("MODEL_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("MODEL_ID", "local-smart"),
    params={
        # Same reasoning-token budget problem as ADR 0007: qwen3 spends the budget thinking
        # before it emits the tool call, and here the "tool call" is the delegation itself.
        "max_tokens": int(os.environ.get("MODEL_MAX_TOKENS", "4096")),
        "temperature": 0.3,
    },
)

SYSTEM_PROMPT = """You are a routing agent. You NEVER answer questions directly.
You MUST always use one of your tools to handle every customer request.

Routing rules:
- Any question mentioning order IDs, order status, tracking, or returns → ask_order_agent
- Product questions, pricing, warranties, shipping policies, or return policies → ask_product_agent
- If a request needs info from both specialists, call them in sequence

IMPORTANT:
- Do NOT attempt to answer from your own knowledge. Always delegate to a specialist.
- Specialists have no memory — they only see what you send them. When the customer's message is ambiguous or references earlier context, enrich the query with the relevant details (order IDs, product names, etc.) from the conversation history before routing."""


# Session-scoped orchestrator factory.
#
# `session_id` / `user_id` become Strands `trace_attributes` -> span attributes `session.id` /
# `user.id`, which Langfuse maps onto the trace's sessionId / userId. Strands binds
# trace_attributes at construction, so this is a factory rather than a module-level agent:
# server.py builds one per session.
#
# Note what is NOT session-scoped here, unlike the 200 agent: nothing about the A2A transport.
# The token is attached per call, so the only reason to cache per session is trace labelling.
def build_session_agent(
    session_id: str | None = None,
    user_id: str | None = None,
):
    trace_attributes = {}
    if session_id:
        trace_attributes["session.id"] = session_id
    if user_id:
        trace_attributes["user.id"] = user_id

    return Agent(
        model=model,
        system_prompt=SYSTEM_PROMPT,
        tools=[ask_order_agent, ask_product_agent],
        trace_attributes=trace_attributes,
    )


if __name__ == "__main__":
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "Where is my order ORD-1001?"
    print(f"\nCUSTOMER: {query}\n")
    build_session_agent()(query)  # no token for local CLI
