"""MCP server — the tools, moved OUT of the agent process.

Local port of the workshop's `500-agent-tools-mcp/mcp-server/server.py`. The only
substantive change is DynamoDB -> SQLite; the tool signatures, docstrings (which are what
the model actually reads to decide), and return shapes are unchanged.

Why this lab matters: in lab 1 `lookup_order` was a Python function imported into the agent.
Here it is a network service the agent discovers at runtime via `list_tools`. That buys four
things — the tools ship independently, they are discoverable, they are shareable across
agents, and, because the call now crosses a network, they are INTERCEPTABLE. Lab 4 spends
that last one.
"""

import json
import os
import sqlite3

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

# DNS rebinding protection blocks in-cluster DNS like `mcp-server.default.svc.cluster.local`.
# That protection matters for browsers hitting localhost; this is a ClusterIP Service only
# other pods talk to, so we turn it off. (Verbatim from the workshop, including the reason.)
mcp = FastMCP(
    "AnyCompany Tools",
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)

ORDERS_DB = os.environ.get("ORDERS_DB", "/data/orders.db")

_CONN = sqlite3.connect(ORDERS_DB, check_same_thread=False)
_CONN.row_factory = sqlite3.Row

INVENTORY = {
    "Laptop Pro 15": 23, "Wireless Mouse": 156, "USB-C Hub": 89,
    "Noise Cancelling Headphones": 45, "Mechanical Keyboard": 67,
    "4K Monitor 27-inch": 12, "Webcam HD Pro": 98,
    "Portable Charger 20000mAh": 203, "Wireless Earbuds": 134, "Laptop Stand": 76,
}


def _order(order_id: str):
    return _CONN.execute(
        "SELECT * FROM orders WHERE order_id = ?", (order_id.upper(),)
    ).fetchone()


@mcp.tool()
def lookup_order(order_id: str) -> dict:
    """Look up order status, tracking, and details by order ID."""
    item = _order(order_id)
    if not item:
        return {"error": f"Order {order_id} not found."}
    items = json.loads(item["items"])
    total = float(sum(i["price"] * i["qty"] for i in items))
    return {
        "order_id": order_id.upper(),
        "customer": item["customer"],
        "items": items,
        "status": item["status"],
        "tracking": item["tracking"],
        "estimated_delivery": item["estimated_delivery"],
        "total": f"${total:.2f}",
    }


@mcp.tool()
def check_inventory(product_name: str) -> dict:
    """Check stock availability for a product."""
    for name, qty in INVENTORY.items():
        if product_name.lower() in name.lower():
            return {"product": name, "in_stock": qty > 0, "quantity": qty}
    return {"error": f"Product '{product_name}' not found in inventory."}


@mcp.tool()
def initiate_return(order_id: str, reason: str) -> dict:
    """Initiate a return for an order. Returns a return authorization number."""
    item = _order(order_id)
    if not item:
        return {"error": f"Order {order_id} not found."}
    if item["status"] == "processing":
        return {"error": "Cannot return an order that hasn't shipped yet. Please cancel instead."}
    return {
        "return_id": f"RET-{order_id.upper().replace('ORD-', '')}",
        "order_id": order_id.upper(),
        "status": "approved",
        "reason": reason,
        "instructions": "Ship the item to: AnyCompany Returns, 100 Warehouse Blvd, Seattle, WA 98101",
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(mcp.streamable_http_app(), host="0.0.0.0", port=8080)
