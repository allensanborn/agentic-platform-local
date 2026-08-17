"""Lab 5: the sandbox air-gap, and the workshop defect it is guarding against.

THIS IS THE MOST IMPORTANT FILE IN THE SUITE.

The workshop's own air-gap NetworkPolicy does not protect a CLAIMED sandbox. Both candidate
selectors miss it: `agents.x-k8s.io/warm-pool-sandbox` is REMOVED by the controller at claim
time, which is precisely when the sandbox starts running untrusted code. The policy looks
correct in every manifest and in every `kubectl get netpol`. It was found only by running
hostile code inside a claimed sandbox and watching it print `EGRESS REACHED THE INTERNET`.
(beads llm-wiki-661.13)

So the assertions here are written against a CLAIMED sandbox, never a pooled one, and every
negative assertion is paired with a control. A "blocked" result proves nothing on its own —
it is equally consistent with a broken network, a crashed pod, or a probe that never ran.
Only "blocked HERE while reaching THERE" isolates the policy as the cause.
"""

import subprocess

import pytest

from conftest import kubectl

PROBE = (
    "cd modules/900-sandbox && . code-executor-mcp/.venv/bin/activate && "
    "python probe.py --url http://127.0.0.1:8090/mcp --escape"
)

CONTROL_POD = "airgap-control-pytest"
CONTROL_OVERRIDES = (
    '{"spec":{"runtimeClassName":"gvisor","containers":[{"name":"c",'
    '"image":"python-runtime-sandbox:local","imagePullPolicy":"Never",'
    '"command":["sleep","300"]}]}}'
)


@pytest.fixture(scope="module")
def escape_probe(forwards):
    """Run the isolation probe inside a claimed sandbox and return its stdout."""
    try:
        proc = subprocess.run(
            PROBE, shell=True, capture_output=True, text=True, timeout=900,
            cwd=_repo_root(),
        )
    except subprocess.TimeoutExpired:
        # Claiming a sandbox means creating a SandboxClaim, scheduling a gVisor pod and
        # importing pandas inside it. Under CPU contention that can take many minutes, and a
        # timeout here says nothing whatsoever about egress. Fail with that stated, so the
        # result is never filed as "the air-gap holds". See llm-wiki-661.23.
        pytest.fail(
            "the sandbox probe timed out — HARNESS/CAPACITY failure, not an air-gap "
            "result. Check cluster CPU (docker stats k3d-agentic-server-0) and node "
            "readiness before re-running; this suite has seen the k3s API starve under "
            "load."
        )
    if proc.returncode != 0:
        pytest.fail(
            "the sandbox probe did not run — this is a harness failure, NOT an air-gap "
            f"result. Do not read it as 'egress blocked'.\nstderr:\n{proc.stderr[-2000:]}"
        )
    return proc.stdout


def _repo_root():
    import pathlib

    return str(pathlib.Path(__file__).resolve().parent.parent)


def test_probe_actually_executed(escape_probe):
    """Guard the guard: assert the probe produced its own markers before trusting them."""
    assert "kernel:" in escape_probe, (
        "probe output has no 'kernel:' marker, so it did not reach the isolation checks; "
        f"every other assertion in this file would be vacuous.\n{escape_probe[-1500:]}"
    )


def test_claimed_sandbox_cannot_reach_the_internet(escape_probe):
    """The defect regression guard. `EGRESS REACHED THE INTERNET` is the failure string."""
    assert "EGRESS REACHED THE INTERNET" not in escape_probe, (
        "A CLAIMED sandbox reached the internet. This is workshop defect #1 "
        "(llm-wiki-661.13): the NetworkPolicy selector stopped matching the pod once it "
        "left the warm pool.\n" + escape_probe[-1500:]
    )
    assert "egress blocked:" in escape_probe, (
        f"no egress verdict in the probe output at all:\n{escape_probe[-1500:]}"
    )


def test_claimed_sandbox_has_no_service_account_token(escape_probe):
    """automountServiceAccountToken: false — no ambient cluster identity to steal."""
    assert "sa token dir exists: False" in escape_probe, (
        f"the sandbox has a service-account token mounted:\n{escape_probe[-1500:]}"
    )


def test_sandbox_runs_on_the_gvisor_kernel(escape_probe):
    """gVisor's userspace kernel reports its own version, distinct from the node's."""
    assert "gvisor" in escape_probe.lower(), (
        "the sandbox is not on the gVisor kernel — it fell back to runc, so the isolation "
        f"boundary is gone while everything still 'works':\n{escape_probe[-1500:]}"
    )


def test_control_pod_reaches_the_internet(forwards):
    """THE CONTROL. Without this, every 'blocked' above is unfalsifiable.

    An identical pod that the NetworkPolicy does not select must reach the internet. If it
    cannot, the cluster has no egress at all and this suite is measuring nothing.
    """
    kubectl("delete", "pod", CONTROL_POD, "-n", "agent-sandbox", "--ignore-not-found")
    try:
        kubectl(
            "run", CONTROL_POD, "-n", "agent-sandbox",
            "--image=python-runtime-sandbox:local", "--restart=Never",
            f"--overrides={CONTROL_OVERRIDES}",
        )
        kubectl(
            "wait", "--for=condition=Ready", f"pod/{CONTROL_POD}",
            "-n", "agent-sandbox", "--timeout=180s",
        )
        out = kubectl(
            "exec", "-n", "agent-sandbox", CONTROL_POD, "--",
            "python3", "-c",
            "import socket;s=socket.socket();s.settimeout(8);"
            "s.connect(('1.1.1.1',443));print('CONTROL-REACHED')",
            timeout=120,
        )
        assert "CONTROL-REACHED" in out, (
            "the unselected control pod could NOT reach the internet, so the sandbox's "
            "'blocked' result is not attributable to the NetworkPolicy"
        )
    finally:
        kubectl(
            "delete", "pod", CONTROL_POD, "-n", "agent-sandbox",
            "--ignore-not-found", "--wait=false",
        )
