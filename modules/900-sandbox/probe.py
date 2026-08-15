"""Drive the code-execution broker over MCP, with or without the gateway in the path.

This exists because the local tool-calling model is weak at multi-tool chaining, and a
flaky model must not be mistaken for a broken broker. This probe is the model-free control:
it speaks MCP directly, so a failure here is the platform's, and a failure that shows up
only through the agent is the model's.

Usage (from a shell with the target port-forwarded):

    # broker directly, no gateway, no JWT
    python probe.py --url http://127.0.0.1:8090/mcp

    # through agentgateway as a persona (lab 4's Keycloak users)
    python probe.py --url http://127.0.0.1:8081/code-mcp --user ana
    python probe.py --url http://127.0.0.1:8081/code-mcp --user sam

    # a chart run: prints the chart_id and saves the PNG via the broker's /chart route
    python probe.py --url http://127.0.0.1:8090/mcp --chart
"""

import argparse
import asyncio
import json
import logging
import sys
import urllib.parse
import urllib.request

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

# The streamable-HTTP client logs a ClosedResourceError traceback when agentgateway closes
# the SSE stream on session teardown. It happens after the result is in hand and says nothing
# about the call, so keep it out of the probe's output.
logging.getLogger("mcp.client.streamable_http").setLevel(logging.CRITICAL)

KEYCLOAK = "http://127.0.0.1:8085"
REALM = "anycompany"
CLIENT_ID = "anycompany-agent"

# A plain aggregation: the answer is a number, so a wrong answer is obvious.
CODE_TEXT = """
import json, pandas as pd
df = pd.DataFrame(json.load(open("/app/orders.json")))
print("rows:", len(df))
print(df.groupby("region")["total"].sum().round(2).to_string())
"""

# A chart run: exercises the bytes -> chart_id -> out-of-band fetch path.
CODE_CHART = """
import json, pandas as pd, matplotlib.pyplot as plt
df = pd.DataFrame(json.load(open("/app/orders.json")))
s = df.groupby("region")["total"].sum().round(2)
print(s.to_string())
fig, ax = plt.subplots(figsize=(7, 4))
s.plot(kind="bar", ax=ax); ax.set_title("2026-Q1 sales by region")
fig.tight_layout(); fig.savefig("/app/chart.png", dpi=100)
"""

# Should be refused by query.py before anything is bound.
CODE_ESCAPE = """
import socket
s = socket.socket(); s.settimeout(5)
try:
    s.connect(("1.1.1.1", 443)); print("EGRESS REACHED THE INTERNET")
except Exception as e:
    print("egress blocked:", type(e).__name__)
import os
print("sa token dir exists:", os.path.exists("/var/run/secrets/kubernetes.io"))
print("kernel:", os.uname().release)
"""


def get_token(user: str) -> str:
    """Password grant against the lab-4 Keycloak realm (password == username)."""
    body = urllib.parse.urlencode({
        "grant_type": "password",
        "client_id": CLIENT_ID,
        "username": user,
        "password": user,
    }).encode()
    url = f"{KEYCLOAK}/realms/{REALM}/protocol/openid-connect/token"
    with urllib.request.urlopen(urllib.request.Request(url, data=body)) as r:
        return json.load(r)["access_token"]


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--user", help="keycloak user (sam | ana); omit for no JWT")
    ap.add_argument("--chart", action="store_true", help="run the matplotlib chart case")
    ap.add_argument("--escape", action="store_true", help="run the isolation-probe code")
    ap.add_argument("--bad-region", action="store_true", help="send a SQL payload as region")
    ap.add_argument("--tools-only", action="store_true", help="just list tools and exit")
    ap.add_argument("--sleep", type=int, default=0,
                    help="hold the sandbox open N seconds so the claim is observable with "
                         "`kubectl get sandboxclaim -n agent-sandbox`")
    args = ap.parse_args()

    headers = {}
    if args.user:
        headers["Authorization"] = f"Bearer {get_token(args.user)}"

    async with streamablehttp_client(args.url, headers=headers) as (r, w, _):
        async with ClientSession(r, w) as session:
            await session.initialize()
            tools = await session.list_tools()
            names = sorted(t.name for t in tools.tools)
            print(f"tools visible: {names}")
            if args.tools_only:
                return 0
            if "run_python" not in names:
                print("run_python is NOT visible to this identity — nothing to call.")
                return 1

            code = CODE_CHART if args.chart else CODE_ESCAPE if args.escape else CODE_TEXT
            if args.sleep:
                code = f"import time\ntime.sleep({args.sleep})\n" + code
            call = {"code": code, "period": "2026-Q1"}
            if args.bad_region:
                call["region"] = "West' OR '1'='1"

            res = await session.call_tool("run_python", call)
            payload = json.loads(res.content[0].text)
            print(json.dumps({k: v for k, v in payload.items() if k != "stdout"}, indent=2))
            print("--- stdout ---")
            print(payload.get("stdout", ""))

            chart_id = payload.get("chart_id")
            if chart_id:
                base = args.url.rsplit("/", 1)[0]
                with urllib.request.urlopen(f"{base}/chart/{chart_id}") as resp:
                    png = resp.read()
                    ctype = resp.headers["content-type"]
                open("/tmp/chart.png", "wb").write(png)
                print(f"chart fetched out-of-band: {len(png)} bytes, {ctype} -> /tmp/chart.png")
                is_png = png[:4] == b"\x89PNG"
                print(f"png magic ok: {is_png}")
            return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
