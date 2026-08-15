"""Agent tools.

Local port of the workshop's `200-strands-agents/customer-agent/tools.py`.

The ONLY change from the original is the storage backend: the workshop reads
DynamoDB via boto3, we read SQLite. The `@tool` signature, the docstring the
model actually sees, and the returned dict are deliberately byte-for-byte the
same, because that is the whole point being demonstrated — the tool contract is
the stable interface, and the datastore behind it is an implementation detail.

Original:
    _TABLE = boto3.resource("dynamodb", ...).Table(os.environ["ORDERS_TABLE"])
    resp = _TABLE.get_item(Key={"order_id": order_id.upper()})
"""

import json
import os
import sqlite3

from strands.tools import tool

ORDERS_DB = os.environ.get("ORDERS_DB", "/data/orders.db")


def _connect() -> sqlite3.Connection:
    # check_same_thread=False: FastAPI serves the agent from a threadpool, and
    # this connection is read-only, so sharing it across threads is safe here.
    conn = sqlite3.connect(ORDERS_DB, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


_CONN = _connect()


@tool
def lookup_order(order_id: str) -> dict:
    """Look up an order by its order ID and return the order details.

    Args:
        order_id: The order ID to look up (e.g., ORD-1001)

    Returns:
        A dictionary containing order details including items, status, tracking number,
        and estimated delivery date. Returns an error message if the order is not found.
    """
    row = _CONN.execute(
        "SELECT * FROM orders WHERE order_id = ?", (order_id.upper(),)
    ).fetchone()

    if row is None:
        return {"error": f"Order {order_id} not found. Please verify the order ID and try again."}

    items = json.loads(row["items"])
    total = float(sum(i["price"] * i["qty"] for i in items))
    return {
        "order_id": row["order_id"],
        "customer": row["customer"],
        "items": items,
        "total": f"${total:.2f}",
        "status": row["status"],
        "tracking_number": row["tracking"],
        "estimated_delivery": row["estimated_delivery"],
        "shipping_address": row["shipping_address"],
    }
