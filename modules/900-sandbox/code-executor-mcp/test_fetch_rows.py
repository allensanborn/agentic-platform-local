"""The SQLite half of the port: _fetch_rows against the repo's real seeded orders.db.

The workshop has no equivalent test (its _fetch_rows talks to DynamoDB), but the shape
contract in run_python's docstring is what the model codes against, so it is worth pinning:
`items` is a list, `total` is a float, and `tracking` is absent — not empty — on orders that
never shipped.
"""

import os
import pathlib

import pytest

_REPO = pathlib.Path(__file__).resolve().parents[3]
_DB = _REPO / "data" / "orders.db"
os.environ.setdefault("ORDERS_DB", str(_DB))

pytestmark = pytest.mark.skipif(not _DB.exists(), reason="run `make seed` first")

import server


def test_period_slice_is_bounded_and_nonempty():
    rows = server._fetch_rows(period="2026-Q1")
    assert rows
    assert {r["period"] for r in rows} == {"2026-Q1"}
    # A quarter is a slice, not the whole table.
    total = server._CONN.execute("SELECT count(*) FROM orders").fetchone()[0]
    assert len(rows) < total


def test_region_filter_narrows_further():
    q1 = server._fetch_rows(period="2026-Q1")
    west = server._fetch_rows(period="2026-Q1", region="West")
    assert west
    assert len(west) < len(q1)
    assert {r["region"] for r in west} == {"West"}


def test_row_shape_matches_the_docstring_contract():
    row = server._fetch_rows(period="2026-Q1")[0]
    assert isinstance(row["items"], list)
    assert {"name", "qty", "price"} <= set(row["items"][0])
    assert isinstance(row["total"], float)


def test_tracking_is_absent_not_empty_for_unshipped_orders():
    rows = server._fetch_rows(period="2026-Q1", status="processing")
    assert rows
    assert all("tracking" not in r for r in rows)


def test_total_sums_the_way_the_docstring_promises():
    for row in server._fetch_rows(period="2026-Q1")[:20]:
        expected = sum(i["price"] * i["qty"] for i in row["items"])
        assert row["total"] == pytest.approx(expected, abs=0.01)
