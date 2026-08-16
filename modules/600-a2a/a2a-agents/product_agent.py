"""The Product specialist — an A2A server whose tool is IN-PROCESS.

Local port of the workshop's `600-multi-agent-a2a/a2a-agents/product_agent.py`.

One substitution, and it is the only one this module forces: the workshop searches a Milvus
collection using fastembed embeddings. Milvus is a multi-pod stateful service and fastembed
bakes a ~90 MB sentence-transformer into the image; neither buys anything for what labs 6 and 8
are about (the A2A hop and where identity is enforced), and both cost more than the rest of
this module combined. `search_products` here is SQLite FTS5 over the workshop's own catalog —
same tool name, same docstring, same returned shape (name / price / description), lexical
matching instead of vector similarity. See ADR 0011.

Worth noticing while reading: `search_products` is a plain Strands `@tool`, running inside this
pod. It is NOT behind agentgateway, so no policy in this cluster can see it, let alone
authorize it. The ONLY control in front of it is the route-grain authn on the A2A hop — which
is exactly the asymmetry ADR 0011 is about. The tool the gateway cannot see is the one an
attacker gets for free once they can reach the specialist at all.
"""

import json
import os
import re
import sqlite3

from strands import Agent
from strands.models.openai import OpenAIModel
from strands.tools import tool
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import InMemoryTaskStore
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.apps import A2AStarletteApplication
from a2a.types import AgentCapabilities, AgentCard, AgentSkill
from a2a.utils.message import new_agent_text_message
import uvicorn

model_base_url = os.environ.get("MODEL_BASE_URL", "http://localhost:4000/v1")
PRODUCTS_JSON = os.environ.get("PRODUCTS_JSON", "/app/products.json")
self_url = os.environ.get(
    "SELF_URL", "http://mcp-gateway.agentgateway-system.svc.cluster.local/product-agent"
)

# An in-memory FTS5 index built at startup. The catalog is 13 rows; there is no reason for it
# to be a network service, and making it one would only add a hop the lab does not teach.
_CATALOG = json.load(open(PRODUCTS_JSON))
_DB = sqlite3.connect(":memory:", check_same_thread=False)
_DB.row_factory = sqlite3.Row
_DB.execute("CREATE VIRTUAL TABLE products USING fts5(name, category, description, price UNINDEXED)")
_DB.executemany(
    "INSERT INTO products (name, category, description, price) VALUES (?, ?, ?, ?)",
    [(p["name"], p["category"], p["description"], p["price"]) for p in _CATALOG],
)
_DB.commit()


def _fts_query(query: str) -> str:
    """Turn free text into an FTS5 OR-query of prefix terms.

    Lexical search has to be forgiving here or it answers nothing: the model sends whole
    questions ("do you sell noise cancelling headphones?"), not keywords. OR-ing prefix terms
    and letting bm25 rank is the cheap stand-in for the vector search's tolerance.
    """
    terms = [t for t in re.findall(r"[A-Za-z0-9]+", query) if len(t) > 2]
    return " OR ".join(f"{t}*" for t in terms) or "product*"


@tool
def search_products(query: str, limit: int = 5) -> list:
    """Search product catalog and FAQs."""
    rows = _DB.execute(
        "SELECT name, description, price FROM products WHERE products MATCH ? "
        "ORDER BY bm25(products) LIMIT ?",
        (_fts_query(query), limit),
    ).fetchall()
    return [
        {
            "name": r["name"],
            "price": f"${r['price']:.2f}" if r["price"] > 0 else "N/A",
            "description": r["description"],
        }
        for r in rows
    ]


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


class ProductAgentExecutor(AgentExecutor):
    def __init__(self):
        self.agent = Agent(
            model=model,
            system_prompt=(
                "You help customers find products. Use search_products to find items. "
                "Be concise with recommendations."
            ),
            tools=[search_products],
        )

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        query = context.get_user_input()
        # No token handling at all — and that is the point. This agent has no MCP call to
        # forward identity to, so the persona simply stops here. Whatever reached this pod is
        # already past every gate the platform has.
        print(f"[a2a-in] product-agent query={query!r}", flush=True)
        reply = str(self.agent(query))
        await event_queue.enqueue_event(new_agent_text_message(reply))

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        pass


agent_card = AgentCard(
    name="Product Agent",
    description="Searches product catalog and answers product questions",
    url=self_url,
    version="1.0.0",
    default_input_modes=["text"],
    default_output_modes=["text"],
    capabilities=AgentCapabilities(streaming=False),
    skills=[
        AgentSkill(
            id="products",
            name="Product Search",
            description="Find products, compare options, check pricing and policies",
            tags=["products", "search", "pricing"],
        )
    ],
)

app = A2AStarletteApplication(
    agent_card=agent_card,
    http_handler=DefaultRequestHandler(
        agent_executor=ProductAgentExecutor(), task_store=InMemoryTaskStore()
    ),
)

if __name__ == "__main__":
    uvicorn.run(app.build(), host="0.0.0.0", port=int(os.environ.get("PORT", "8082")))
