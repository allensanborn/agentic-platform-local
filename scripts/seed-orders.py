#!/usr/bin/env python3
"""Build data/orders.db (SQLite) from data/orders.json.

Stands in for the workshop's `terraform/dynamodb.tf` + `scripts/load_orders.sh`.
The source rows are the workshop's own 500-order dataset, converted out of
DynamoDB's typed JSON ({"S": "..."}) into plain JSON.

Columns mirror the DynamoDB item attributes exactly so the lab-5 analytics
tool (scoped, parameterized queries over period/region/status) can be added
later without reshaping the data.
"""

import json
import pathlib
import sqlite3
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "data" / "orders.json"
DST = ROOT / "data" / "orders.db"

COLUMNS = [
    "order_id", "customer", "status", "tracking", "estimated_delivery",
    "shipping_address", "items", "order_date", "period", "region",
    "state", "payment_method", "channel", "total",
]


def main() -> int:
    if not SRC.exists():
        print(f"missing {SRC}", file=sys.stderr)
        return 1

    rows = json.loads(SRC.read_text())
    DST.unlink(missing_ok=True)

    conn = sqlite3.connect(DST)
    conn.execute(
        f"CREATE TABLE orders ({', '.join(f'{c} TEXT' for c in COLUMNS)}, PRIMARY KEY (order_id))"
    )
    # `items` is stored as a JSON string, exactly as DynamoDB held it, so
    # tools.py's json.loads(row["items"]) matches the workshop line for line.
    conn.executemany(
        f"INSERT INTO orders ({', '.join(COLUMNS)}) VALUES ({', '.join('?' * len(COLUMNS))})",
        [
            tuple(
                json.dumps(r[c]) if c == "items" else str(r.get(c, ""))
                for c in COLUMNS
            )
            for r in rows
        ],
    )
    conn.execute("CREATE INDEX idx_period_region ON orders (period, region)")
    conn.commit()

    n = conn.execute("SELECT count(*) FROM orders").fetchone()[0]
    sample = conn.execute("SELECT order_id, status FROM orders LIMIT 3").fetchall()
    conn.close()
    print(f"wrote {DST} — {n} orders; sample {sample}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
