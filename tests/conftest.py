"""Shared fixtures for the deterministic infra suite.

Two design rules run through this file, both of them paid for.

1. THE SUITE OWNS ITS PORT-FORWARDS. Every ad-hoc check in the Makefile assumes you
   already ran `make forwards` in another shell. When you have not, `make sandbox-airgap`
   dies inside httpx with `ConnectError: All connection attempts failed` — a traceback that
   reads like an air-gap result and is actually a missing tunnel. A test that can fail for
   that reason is worse than no test, so the `forwards` fixture starts what it needs, waits
   for each one to actually answer, and tears them down.

2. NOTHING ASSERTS ON A COMMAND THAT MIGHT NOT HAVE RUN. `kubectl()` raises on non-zero
   exit rather than returning empty output. Three separate times in this project a failed
   command's empty output was read as a meaningful zero (`grep -c` on a failed `ls-remote`,
   `curl` in a container with no curl, `ls -l | awk` against a shell alias). An empty result
   must be distinguishable from a broken invocation, always.
"""

import json
import os
import socket
import subprocess
import time
import urllib.parse
import urllib.request
from contextlib import closing

import pytest

NAMESPACE_OF = {
    "mcp-gateway": "agentgateway-system",
    "keycloak": "identity",
    "customer-agent": "default",
    "code-executor-mcp": "default",
    "langfuse-web": "langfuse",
    "ai-gateway": "envoy-gateway-system",
}

# local_port -> (service, remote_port). Ports match the Makefile's `forwards` target where
# they overlap, so a developer can run the suite against tunnels they already have open.
FORWARDS = {
    8081: ("mcp-gateway", 80),
    8085: ("keycloak", 8080),
    8082: ("customer-agent", 8080),
    8090: ("code-executor-mcp", 8080),
    3000: ("langfuse-web", 3000),
    18080: ("ai-gateway", 80),
}

KEYCLOAK = "http://127.0.0.1:8085"
REALM = "anycompany"
CLIENT_ID = "anycompany-agent"

# Seeded by the Langfuse deployment's LANGFUSE_INIT_* env; see platform/observability.
LANGFUSE = "http://127.0.0.1:3000"
LANGFUSE_PK = "pk-lf-agentic-platform-local"
LANGFUSE_SK = "sk-lf-agentic-platform-local"


# Transient API-server unavailability is NORMAL on this box, not exceptional. The k3s
# datastore is kine-on-SQLite, and a burst (Langfuse starting, a sandbox claim, model
# inference) can starve it enough that the API server stops completing TLS handshakes for
# tens of seconds. Controllers then restart, re-list everything, and add load — a feedback
# loop that resolves on its own once the burst passes. A suite that treats the first
# `TLS handshake timeout` as a product failure reports garbage; see llm-wiki-661.23.
TRANSIENT = (
    "TLS handshake timeout",
    "connection refused",
    "i/o timeout",
    "unexpected EOF",
    "etcdserver: request timed out",
    "Unable to connect to the server",
)


def kubectl(*args, timeout=60, retries=4):
    """Run kubectl and return stdout.

    Raises on failure — never returns empty output on error, because an empty string that
    might mean "no results" or might mean "the command died" is unassertable. Retries only
    on the transient API-availability errors listed above; a genuine NotFound or a bad
    manifest fails immediately.
    """
    last = None
    for attempt in range(retries):
        proc = subprocess.run(
            ["kubectl", *args], capture_output=True, text=True, timeout=timeout
        )
        if proc.returncode == 0:
            return proc.stdout
        last = proc
        if not any(t in proc.stderr for t in TRANSIENT):
            break
        time.sleep(5 * (attempt + 1))
    raise RuntimeError(
        f"kubectl {' '.join(args)} failed (rc={last.returncode})\n"
        f"stdout: {last.stdout}\nstderr: {last.stderr}"
    )


def explain(exc):
    """Flatten an exception, its ExceptionGroup members and its __cause__ chain into text.

    The MCP streamable-HTTP client runs inside an anyio TaskGroup, so a plain HTTP 401
    surfaces as:

        ExceptionGroup: unhandled errors in a TaskGroup (1 sub-exception)

    `str()` of that contains no status code, no URL, nothing. Asserting on `str(exc)` reports
    "not a 401" for something that is exactly a 401. The same wrapper cost real time when it
    hid the root cause of the A2A bearer bug (llm-wiki-661.20) behind an opaque TaskGroup
    message. Anything in this suite that inspects an exception must go through here.
    """
    seen, out = set(), []

    def walk(e, depth=0):
        if e is None or id(e) in seen or depth > 10:
            return
        seen.add(id(e))
        out.append(f"{type(e).__name__}: {e}")
        for sub in getattr(e, "exceptions", ()) or ():
            walk(sub, depth + 1)
        walk(getattr(e, "__cause__", None), depth + 1)
        walk(getattr(e, "__context__", None), depth + 1)

    walk(exc)
    return "\n".join(out)


def _port_open(port):
    with closing(socket.socket()) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


@pytest.fixture(scope="session", autouse=True)
def capacity_gate():
    """Refuse to run while the cluster is mid-collapse, and say so in those words.

    On this box the k3s API can starve under burst load: kine-on-SQLite slows, controllers
    fail to renew their leader-election lease, controller-runtime treats that as fatal and
    exits, Kubernetes restarts them, and the restart's re-LIST adds more load. See
    llm-wiki-661.23 for the full mechanism.

    During that window real assertions fail for reasons that have nothing to do with the code
    under test — the Gateway sits Programmed=False, MCP calls time out, port-forwards never
    come up. Reporting those as product failures is worse than not running, so this gate
    fails fast with an unambiguous message instead.
    """
    problems = []
    try:
        nodes = json.loads(kubectl("get", "nodes", "-o", "json", retries=2))["items"]
    except RuntimeError as e:
        pytest.exit(f"CAPACITY HOLD: the Kubernetes API is not answering.\n{e}", returncode=2)

    for n in nodes:
        ready = next(
            (c for c in n["status"]["conditions"] if c["type"] == "Ready"), None
        )
        if not ready or ready["status"] != "True":
            problems.append(f"node {n['metadata']['name']} is not Ready")

    pods = json.loads(kubectl("get", "pods", "-A", "-o", "json", retries=2))["items"]
    for p in pods:
        for cs in p["status"].get("containerStatuses", []):
            reason = cs.get("state", {}).get("waiting", {}).get("reason", "")
            if reason == "CrashLoopBackOff":
                problems.append(
                    f"{p['metadata']['namespace']}/{p['metadata']['name']} CrashLoopBackOff"
                )

    # Node-level health is NOT sufficient. After a collapse the controllers come back
    # Running (so the CrashLoopBackOff check above passes) while the Gateway is still
    # Programmed=False, and every request through it fails with a connection error that
    # looks like a broken agent. Observed with 32 controller restarts, both nodes Ready and
    # CPU at 36%. Check the data plane is actually programmed.
    try:
        conds = json.loads(
            kubectl("get", "gateway", "envoy-ai-gateway", "-o", "json", retries=2)
        )["status"]["conditions"]
        programmed = next((c for c in conds if c["type"] == "Programmed"), None)
        if not programmed or programmed["status"] != "True":
            problems.append(
                "Gateway envoy-ai-gateway is not Programmed "
                f"({programmed['status'] if programmed else 'condition absent'}) — the data "
                "plane has no config, so every model call will fail"
            )
    except (RuntimeError, KeyError, TypeError) as e:
        problems.append(f"could not read Gateway envoy-ai-gateway status: {e}")

    if problems:
        pytest.exit(
            "CAPACITY HOLD — the cluster is degraded, so this run would produce misleading "
            "failures. This is NOT a product failure.\n  "
            + "\n  ".join(problems)
            + "\n\nWait for it to settle (watch `docker stats k3d-agentic-server-0`), then "
            "re-run. See beads llm-wiki-661.23.",
            returncode=2,
        )


@pytest.fixture(scope="session")
def forwards(capacity_gate):
    """Start every port-forward the suite needs; yield when they all answer.

    Reuses a tunnel that is already open (so this composes with `make forwards`) and only
    tears down the ones it started itself.
    """
    started = []
    for local, (svc, remote) in FORWARDS.items():
        if _port_open(local):
            continue
        proc = subprocess.Popen(
            [
                "kubectl", "port-forward",
                "-n", NAMESPACE_OF[svc], f"svc/{svc}", f"{local}:{remote}",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        started.append((local, proc))

    deadline = time.time() + 60
    pending = {local for local, _ in started}
    while pending and time.time() < deadline:
        pending = {p for p in pending if not _port_open(p)}
        if pending:
            time.sleep(0.5)
    if pending:
        for _, proc in started:
            proc.terminate()
        raise RuntimeError(
            f"port-forwards never became ready: {sorted(pending)}. "
            "Is the cluster up? (make up-all)"
        )

    yield

    for _, proc in started:
        proc.terminate()
    for _, proc in started:
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


@pytest.fixture(scope="session")
def token(forwards):
    """Mint a Keycloak access token for a persona. Same path probe.py uses."""
    cache = {}

    def _token(user):
        if user not in cache:
            body = urllib.parse.urlencode(
                {
                    "grant_type": "password",
                    "client_id": CLIENT_ID,
                    "username": user,
                    "password": user,
                }
            ).encode()
            url = f"{KEYCLOAK}/realms/{REALM}/protocol/openid-connect/token"
            with urllib.request.urlopen(url, data=body, timeout=30) as r:
                cache[user] = json.load(r)["access_token"]
        return cache[user]

    return _token


@pytest.fixture(scope="session")
def langfuse(forwards):
    """GET against the Langfuse API with Basic auth.

    v1 ONLY. /api/public/v2/traces and /api/public/v2/observations are 404 on the deployed
    3.x — v2 covers only prompts and scores. See the correction block in ADR 0012.
    """
    import base64

    creds = base64.b64encode(f"{LANGFUSE_PK}:{LANGFUSE_SK}".encode()).decode()

    def _get(path, params=None):
        url = f"{LANGFUSE}{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={"Authorization": f"Basic {creds}"})
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)

    return _get
