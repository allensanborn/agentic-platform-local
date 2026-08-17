"""Tier 0: the cluster came up, and came up completely.

This is the regression guard for the cold start. It is deliberately the cheapest and
first-ordered file in the suite: if these fail, every later assertion is noise.
"""

import json

import pytest

from conftest import kubectl

# Deployments the labs depend on. Named individually rather than "count > N" so a MISSING
# component fails loudly instead of being masked by an unrelated one being present.
REQUIRED = [
    ("envoy-gateway-system", "envoy-gateway"),
    ("envoy-ai-gateway-system", "ai-gateway-controller"),
    ("agentgateway-system", "agentgateway"),
    ("agentgateway-system", "mcp-gateway"),
    ("agent-sandbox-system", "agent-sandbox-controller"),
    ("default", "customer-agent"),
    ("default", "mcp-server"),
    ("default", "code-executor-mcp"),
    ("identity", "keycloak"),
    ("telemetry", "otel-collector"),
    ("langfuse", "langfuse-web"),
]


def test_no_pod_is_unhealthy():
    """Every pod is Running or Succeeded — no CrashLoop, no ImagePullBackOff, no Pending."""
    pods = json.loads(kubectl("get", "pods", "-A", "-o", "json"))["items"]
    assert pods, "no pods at all — is the cluster up?"

    bad = []
    for p in pods:
        phase = p["status"]["phase"]
        if phase not in ("Running", "Succeeded"):
            bad.append(f"{p['metadata']['namespace']}/{p['metadata']['name']}: {phase}")
            continue
        # A pod can be Running with a container stuck restarting; Running is not enough.
        for cs in p["status"].get("containerStatuses", []):
            waiting = cs.get("state", {}).get("waiting")
            if waiting:
                bad.append(
                    f"{p['metadata']['namespace']}/{p['metadata']['name']}"
                    f" container {cs['name']}: {waiting.get('reason')}"
                )
    assert not bad, "unhealthy pods:\n  " + "\n  ".join(bad)


@pytest.mark.parametrize("namespace,name", REQUIRED, ids=[f"{n}/{d}" for n, d in REQUIRED])
def test_required_deployment_is_available(namespace, name):
    """Each lab's control point exists and has an available replica."""
    dep = json.loads(kubectl("get", "deploy", name, "-n", namespace, "-o", "json"))
    available = dep["status"].get("availableReplicas", 0)
    assert available >= 1, f"{namespace}/{name} has {available} available replicas"


def test_gvisor_runtimeclass_exists():
    """Lab 5's isolation boundary is a RuntimeClass; without it sandboxes silently run runc."""
    out = kubectl("get", "runtimeclass", "gvisor", "-o", "jsonpath={.handler}")
    assert out.strip() == "runsc", f"gvisor RuntimeClass handler is {out.strip()!r}, want 'runsc'"
