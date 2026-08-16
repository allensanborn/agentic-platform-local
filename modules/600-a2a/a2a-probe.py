"""Drive the A2A specialists directly, with the gateway in the path and no model in the way.

Same reason `modules/900-sandbox/probe.py` exists: the local tool-calling model is weak at
multi-tool chaining, and a flaky router must not be mistaken for a broken hop. This probe
speaks raw A2A JSON-RPC 2.0 over HTTP, so a failure here is the platform's, and a failure that
appears only through the orchestrator is the model's.

Deliberately stdlib-only (urllib, no a2a-sdk, no httpx) so it runs against the port-forwarded
gateway with the system Python and no virtualenv.

Usage (needs `make a2a-forward` running):

    # agent card through the gateway — cheap, no model, exercises the same route + policy
    python3 a2a-probe.py --agent order   --card
    python3 a2a-probe.py --agent order   --card --user sam
    python3 a2a-probe.py --agent product --card --user ana

    # a real delegation: message/send, which runs the specialist's model
    python3 a2a-probe.py --agent order --user sam  --text "Where is order ORD-1001?"
    python3 a2a-probe.py --agent order --user ana  --text "Return ORD-1002, it arrived damaged"

    # the specialist's Service directly, bypassing the gateway entirely
    python3 a2a-probe.py --url http://127.0.0.1:8181 --card
"""

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

KEYCLOAK = "http://127.0.0.1:8085"
REALM = "anycompany"
CLIENT_ID = "anycompany-agent"
GATEWAY = "http://127.0.0.1:8081"

AGENTS = {"order": "/order-agent", "product": "/product-agent"}


def get_token(user: str) -> str:
    """Password grant against the lab-4 Keycloak realm (password == username)."""
    body = urllib.parse.urlencode({
        "grant_type": "password",
        "client_id": CLIENT_ID,
        "username": user,
        "password": user,
    }).encode()
    url = f"{KEYCLOAK}/realms/{REALM}/protocol/openid-connect/token"
    with urllib.request.urlopen(urllib.request.Request(url, data=body), timeout=30) as r:
        return json.load(r)["access_token"]


def _call(url: str, token: str | None, payload: dict | None, timeout: int):
    """Return (status, body_text). A 4xx is a RESULT here, not an error to raise."""
    headers = {}
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as e:  # connection refused, timeout, ...
        return None, f"{type(e).__name__}: {e}"


def _extract_text(body: str) -> str:
    """Pull the reply text out of a JSON-RPC SendMessageResponse (Message or Task)."""
    try:
        doc = json.loads(body)
    except Exception:
        return body[:400]
    if "error" in doc:
        return f"JSON-RPC error: {doc['error']}"
    result = doc.get("result", doc)
    parts = list(result.get("parts") or [])
    for artifact in result.get("artifacts") or []:
        parts.extend(artifact.get("parts") or [])
    status_msg = (result.get("status") or {}).get("message") or {}
    parts.extend(status_msg.get("parts") or [])
    texts = [p.get("text") for p in parts if p.get("text")]
    return "\n".join(texts) or json.dumps(result)[:400]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent", choices=sorted(AGENTS), help="which specialist, via the gateway")
    ap.add_argument("--url", help="explicit base URL (bypasses --agent/--gateway)")
    ap.add_argument("--gateway", default=GATEWAY)
    ap.add_argument("--user", help="Keycloak persona; omit to send NO token")
    ap.add_argument("--card", action="store_true", help="GET the agent card instead of sending a message")
    ap.add_argument("--text", default="Where is order ORD-1001?")
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--quiet", action="store_true", help="print only 'STATUS <code>'")
    args = ap.parse_args()

    if args.url:
        base = args.url.rstrip("/")
    elif args.agent:
        base = args.gateway.rstrip("/") + AGENTS[args.agent]
    else:
        ap.error("one of --agent or --url is required")

    token = get_token(args.user) if args.user else None

    if args.card:
        # The card is a plain GET on the same route, so it crosses the same HTTPRoute and the
        # same AgentgatewayPolicy as message/send — a model-free way to read the gate.
        status, body = _call(f"{base}/.well-known/agent-card.json", token, None, 30)
        label = "card"
    else:
        payload = {
            "jsonrpc": "2.0",
            "id": str(uuid.uuid4()),
            "method": "message/send",
            "params": {
                "message": {
                    "kind": "message",
                    "messageId": str(uuid.uuid4()),
                    "role": "user",
                    "parts": [{"kind": "text", "text": args.text}],
                }
            },
        }
        status, body = _call(base, token, payload, args.timeout)
        label = "message/send"

    who = args.user or "NO TOKEN"
    if args.quiet:
        print(f"STATUS {status}")
        return 0 if status == 200 else 1

    print(f"{label:14s} {base}")
    print(f"  as:     {who}")
    print(f"  status: {status}")
    if status == 200 and not args.card:
        print(f"  reply:  {_extract_text(body)}")
    elif status == 200 and args.card:
        doc = json.loads(body)
        print(f"  card:   {doc.get('name')} — skills={[s.get('id') for s in doc.get('skills', [])]}")
    else:
        print(f"  body:   {body[:300]}")
    return 0 if status == 200 else 1


if __name__ == "__main__":
    sys.exit(main())
