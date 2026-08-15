"""Integration-ish test for the broker's GET /chart/{id} custom route.

Exercises the real Starlette app FastMCP builds, so the route wiring (path,
method, 200 vs 404, content-type) is covered end to end. No sandbox is vended
here — we only touch the chart cache + route — but server.py opens the orders
SQLite DB at import, so point it at the repo's seeded copy first.
"""

import os
import pathlib

_REPO = pathlib.Path(__file__).resolve().parents[3]
os.environ.setdefault("ORDERS_DB", str(_REPO / "data" / "orders.db"))

from starlette.testclient import TestClient

import server


def _client():
    return TestClient(server.mcp.streamable_http_app())


def test_get_chart_returns_png_bytes():
    chart_id = server._charts.put(b"\x89PNG-fake-bytes")
    resp = _client().get(f"/chart/{chart_id}")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/png"
    assert resp.content == b"\x89PNG-fake-bytes"


def test_get_chart_unknown_id_is_404():
    resp = _client().get("/chart/c_nope")
    assert resp.status_code == 404


def test_get_chart_is_not_cached_downstream():
    chart_id = server._charts.put(b"x")
    resp = _client().get(f"/chart/{chart_id}")
    assert resp.headers.get("cache-control") == "no-store"
