"""Lab 2: one chat turn is ONE trace spanning two services.

The property: the agent's `/chat` server span and the gateway's Envoy spans belong to the
same tree, because W3C traceparent survives the hop. Two disconnected traces is the failure
mode, and it is a subtle one — a naive check for "spans from two services exist" PASSES in
the broken state, because both services do emit spans; they just do not join.

ADR 0004 records that this exact property was believed broken for a while and was
misdiagnosed twice (once blaming Envoy when the collector Service was missing
`appProtocol: grpc`; once querying a backend that had already been deleted). So the
assertion here is specifically "an Envoy span exists AND descends from the agent's root".

API note: v1 endpoints only. `/api/public/v2/traces` and `/api/public/v2/observations` are
404 on the deployed Langfuse 3.x — v2 covers only prompts and scores. See ADR 0012.
"""

import json
import time
import urllib.request
import uuid

import pytest

AGENT = "http://127.0.0.1:8082/chat"


def _ask(question, session_id, access_token=None, timeout=300):
    """Drive one chat turn through the agent, draining the SSE stream.

    The field is `query`, not `message` — see ChatRequest in
    modules/200-agent/customer-agent/server.py. A wrong key here is a 422, not a test failure.
    """
    payload = {"query": question, "session_id": session_id}
    if access_token:
        payload["access_token"] = access_token
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        AGENT, data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode(errors="replace")


def _wait_for_trace(langfuse, session_id, timeout=120):
    """Poll until the trace lands.

    OTLP export is asynchronous and batched (BatchSpanProcessor, then the collector's batch
    processor, then Langfuse's own ingestion queue), so the trace is NOT there when /chat
    returns. Never sleep-and-hope.
    """
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = langfuse("/api/public/traces", {"sessionId": session_id})
        if last.get("data"):
            return last["data"][0]["id"]
        time.sleep(3)
    raise AssertionError(
        f"no trace for session {session_id} within {timeout}s (last response: {last})"
    )


@pytest.fixture(scope="module")
def observations(forwards, langfuse, token):
    """One real chat turn, then its observations once fully ingested.

    The access_token is REQUIRED, not optional: the agent builds a per-request MCP client and
    the MCP gateway runs jwtAuthentication mode: Strict, so a tokenless /chat fails with an
    MCPClientInitializationError wrapping a 401 and returns HTTP 500. That is lab 4 working,
    not a bug — but it makes the token part of the contract for any test that drives /chat.
    """
    sid = f"pytest-{uuid.uuid4()}"
    _ask("My order ID is ORD-1001. Where is it?", sid, access_token=token("ana"))
    trace_id = _wait_for_trace(langfuse, sid)

    # A partially-ingested trace is not a negative result. Wait for the gateway spans to
    # arrive too, otherwise a slow collector looks identical to broken propagation.
    deadline = time.time() + 90
    obs = []
    while time.time() < deadline:
        obs = langfuse(f"/api/public/traces/{trace_id}").get("observations", [])
        if any(_is_gateway(o) for o in obs):
            break
        time.sleep(3)
    return obs


def _is_gateway(o):
    """Envoy span names are library-version artefacts; match on substrings, not equality."""
    name = (o.get("name") or "").lower()
    return "ext_proc" in name or name.startswith("router ") or "envoy" in name


def _is_root(o):
    return (o.get("name") or "").startswith("POST /chat")


def test_the_trace_exists_at_all(observations):
    assert observations, "the trace has no observations — OTLP export is not reaching Langfuse"


def test_gateway_spans_are_present(observations):
    """If Envoy contributes nothing, traceparent propagation or Envoy tracing is off."""
    assert [o for o in observations if _is_gateway(o)], (
        "no gateway spans in the trace. Check EnvoyProxy telemetry.tracing.samplingRate "
        "(Envoy samples independently of the OTel SDK) before suspecting traceparent.\n"
        f"names seen: {[o.get('name') for o in observations][:25]}"
    )


def test_gateway_spans_descend_from_the_agent_root(observations):
    """THE lab-2 assertion: one tree, not two.

    The weaker check — 'spans from both services exist' — passes even when the trace did not
    join, which is exactly the regression worth catching.
    """
    by_id = {o["id"]: o for o in observations}
    roots = [o for o in observations if _is_root(o)]
    assert roots, (
        "no 'POST /chat' root span found; cannot test parentage.\n"
        f"names seen: {[o.get('name') for o in observations][:25]}"
    )
    root_ids = {r["id"] for r in roots}

    def ancestors(o):
        seen = set()
        while o.get("parentObservationId"):
            pid = o["parentObservationId"]
            if pid in seen or pid not in by_id:
                return
            seen.add(pid)
            o = by_id[pid]
            yield o

    gateway = [o for o in observations if _is_gateway(o)]
    joined = [g for g in gateway if any(a["id"] in root_ids for a in ancestors(g))]
    assert joined, (
        "gateway spans exist but none descends from the /chat root — the trace did not "
        "join, so latency cannot be attributed across the model hop. This is two "
        "disconnected trees, the exact failure ADR 0004 documents."
    )


def test_sse_chunk_spans_are_still_filtered(observations):
    """ADR 0004: a per-SSE-chunk span explosion (543 -> 9) is filtered at the collector.

    An upper bound, not an equality check — the exact count is a Langfuse remodelling
    artefact and will drift on upgrade, but a return to hundreds means the filter is gone.
    """
    http_sends = [o for o in observations if (o.get("name") or "") == "POST /chat http send"]
    assert not http_sends, (
        f"{len(http_sends)} per-chunk 'http send' spans present — the collector's "
        "drop_sse_chunk_spans filter is not being applied"
    )
    assert len(observations) < 150, (
        f"{len(observations)} observations in one turn; the SSE span explosion appears to "
        "have returned"
    )
