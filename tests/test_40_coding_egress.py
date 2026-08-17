"""Labs 6 + 7: the coding sandbox's two-destination egress allowlist.

The coding agent needs exactly two things — the AI gateway (to think) and Gitea (to push).
Everything else is denied: the MCP gateway, the Kubernetes API, and the open internet. That
allowlist is the whole security story of the autonomous-coding labs, because the workload
inside is a model writing and running its own code against a real repository.

Same discipline as the air-gap file: every DENY is paired with the same probe from a pod the
policy does not select, so a deny is attributable to the policy rather than to a broken
network. The existing `verify-egress.sh` already encodes the destination list and the claim
logic; this wraps it rather than duplicating it, and asserts on its per-destination verdicts.
"""

import pathlib
import re
import subprocess

import pytest

SCRIPT = "modules/1000-coding-agent/verify-egress.sh"

# destination label -> expected verdict inside the CLAIMED sandbox
EXPECTED = {
    "AI gateway": "REACHED",
    "Gitea": "REACHED",
    "mcp-gateway": "blocked",
    "kube API": "blocked",
    "internet IP": "blocked",
    "internet DNS": "blocked",
}


def _repo_root():
    return pathlib.Path(__file__).resolve().parent.parent


@pytest.fixture(scope="module")
def egress_output(forwards):
    proc = subprocess.run(
        ["bash", SCRIPT], capture_output=True, text=True, timeout=600, cwd=_repo_root()
    )
    if proc.returncode != 0 and "REACHED" not in proc.stdout:
        pytest.fail(
            "verify-egress.sh did not run to completion — harness failure, not an egress "
            f"result.\nstdout:\n{proc.stdout[-2000:]}\nstderr:\n{proc.stderr[-1000:]}"
        )
    return proc.stdout


def _verdicts(block):
    """Map destination label -> REACHED/blocked from one section of the script's output."""
    found = {}
    for line in block.splitlines():
        m = re.search(r"\]\s+(REACHED|blocked)\s+(.+?)\s+\(sandbox:", line)
        if m:
            found[m.group(2).strip()] = m.group(1)
    return found


@pytest.fixture(scope="module")
def sections(egress_output):
    """Split the sandbox section from the control section.

    The script prints the claimed sandbox first, then the CONTROL header, then the same
    probes from an unselected pod.
    """
    parts = re.split(r"===\s*CONTROL", egress_output, maxsplit=1)
    assert len(parts) == 2, (
        "could not find the CONTROL section in verify-egress.sh output; without it the "
        f"deny results are unfalsifiable.\n{egress_output[-1500:]}"
    )
    return _verdicts(parts[0]), _verdicts(parts[1])


@pytest.mark.parametrize("destination,expected", sorted(EXPECTED.items()))
def test_sandbox_egress_matches_the_allowlist(sections, destination, expected):
    sandbox, _ = sections
    assert destination in sandbox, (
        f"no verdict for {destination!r} in the sandbox section: {sandbox}"
    )
    assert sandbox[destination] == expected, (
        f"{destination}: expected {expected}, got {sandbox[destination]}. "
        "The coding sandbox's egress allowlist has drifted."
    )


@pytest.mark.parametrize("destination", sorted(EXPECTED))
def test_control_pod_reaches_everything(sections, destination):
    """THE CONTROL. An unselected pod must reach all six, including the four denied above."""
    _, control = sections
    assert control.get(destination) == "REACHED", (
        f"the control pod did not reach {destination!r} (got {control.get(destination)!r}). "
        "The sandbox's 'blocked' verdicts are therefore not attributable to the "
        "NetworkPolicy — they may just be a broken network."
    )


def test_sandbox_has_no_service_account_token(egress_output):
    sandbox_part = re.split(r"===\s*CONTROL", egress_output, maxsplit=1)[0]
    assert "token dir exists: False" in sandbox_part, (
        f"the coding sandbox has a service-account token mounted:\n{sandbox_part[-1200:]}"
    )
