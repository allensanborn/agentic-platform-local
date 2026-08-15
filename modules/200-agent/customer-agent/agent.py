"""The customer agent — now discovering its tools over MCP.

Local port of the workshop's `500-agent-tools-mcp/customer-agent/agent.py`.

What changed from lab 1: `lookup_order` is no longer imported. The agent connects to an MCP
endpoint and calls `list_tools` at runtime, so the tools it has are whatever the server
advertises. It gained `check_inventory` and `initiate_return` without an agent rebuild.

The session-scoped client is not incidental structure. Strands' MCPClient binds its auth ONCE,
when the transport connects, and binds each discovered tool to the client that listed it. A
single import-time client shared by every user therefore cannot carry a per-user token — so
the agent is built per session. Lab 4 spends that: it passes the caller's bearer here and the
gateway decides which tools this persona may even see. Building it now means lab 4 adds a
parameter rather than a redesign.

One consequence worth knowing before it surprises you: tool discovery happens on the FIRST
CHAT MESSAGE of a session, not at pod startup. After changing an authorization policy, start a
new conversation or you will be looking at a cached tool list.
"""

import os
import sys

from strands import Agent
from strands.models.openai import OpenAIModel
from strands.tools.mcp import MCPClient
from mcp.client.streamable_http import streamablehttp_client

# MODEL_* point at an OpenAI-compatible LLM gateway (lab 0). The agent still has no idea
# which model is behind the alias, and still holds no credential.
model_base_url = os.environ.get("MODEL_BASE_URL", "http://localhost:4000/v1")

# One agent can front SEVERAL MCP servers (the orders tools now; the code-exec broker in
# lab 5). Comma-separated list, falling back to the single-URL form.
def _mcp_server_urls() -> list[str]:
    raw = os.environ.get("MCP_SERVER_URLS", "").strip()
    if raw:
        return [u.strip() for u in raw.split(",") if u.strip()]
    return [os.environ.get("MCP_SERVER_URL", "http://localhost:8080/mcp")]


model = OpenAIModel(
    client_args={
        "base_url": model_base_url,
        "api_key": os.environ.get("MODEL_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("MODEL_ID", "local-smart"),
    params={"max_tokens": 2048, "temperature": 0.3},
)

SYSTEM_PROMPT = """You are a friendly and helpful customer service agent for AnyCompany Shop, an online retail store.

Your job is to assist customers with:
1. Order inquiries — use the lookup_order tool to check order status, shipping updates, delivery estimates
2. Product questions — help customers find the right product, compare options, check availability
3. Returns and refunds — guide customers through the return process, explain policies
4. General support — answer FAQs about shipping, payment methods, and store policies

Guidelines:
- Be warm, professional, and concise
- If you don't have enough information to help, ask clarifying questions
- Always confirm the customer's issue before suggesting a solution
- For order-related queries, ask for the order ID if not provided, then use the lookup_order tool
- Present order information in a clear, readable format
- Never make up order details — always use the lookup_order tool
"""


def build_session_agent(access_token: str | None = None, session_id: str | None = None):
    """Return (agent, mcp_clients). The caller owns the clients' lifetime.

    `access_token` is forwarded as a bearer on every MCP call. It is unused in lab 3 (nothing
    enforces anything yet) and load-bearing in lab 4.
    """
    headers = {"Authorization": f"Bearer {access_token}"} if access_token else None

    clients, tools = [], []
    for url in _mcp_server_urls():
        client = MCPClient(lambda u=url: streamablehttp_client(u, headers=headers))
        client.__enter__()
        clients.append(client)
        discovered = client.list_tools_sync()
        tools.extend(discovered)
        print(f"Discovered {len(discovered)} MCP tools at {url}: "
              f"{[t.tool_name for t in discovered]}", flush=True)

    trace_attributes = {"session.id": session_id} if session_id else {}

    agent = Agent(
        model=model,
        system_prompt=SYSTEM_PROMPT,
        tools=tools,
        trace_attributes=trace_attributes,
    )
    return agent, clients


if __name__ == "__main__":
    query = " ".join(sys.argv[1:]) or "My order ID is ORD-1001. Where is it?"
    agent, clients = build_session_agent()
    print(f"\n{'=' * 60}\nCUSTOMER: {query}\n{'=' * 60}\n")
    agent(query)
    for c in clients:
        c.__exit__(None, None, None)
