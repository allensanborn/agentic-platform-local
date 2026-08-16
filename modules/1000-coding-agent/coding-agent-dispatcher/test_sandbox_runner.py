"""Tests for the pure script builders.

Carried over from the workshop's own test file. These would have caught the
no-shell / no-env-passthrough bug: run.sh MUST be self-contained (export its own
HOME + GITEA_TOKEN) because the runtime's /execute runs shlex.split + subprocess
with no shell and no env passthrough, and the command sent is only
`bash /app/run.sh`.

Two workshop tests are gone and one is new, all for the same reason: the Claude
Code stream renderer and the `claude -p` invocation moved OUT of the dispatcher
and INTO the sandbox image, behind the /opt/agents/ contract. The tests that
asserted on `claude`-specific strings in run.sh now assert on the seam instead —
which is the property that actually matters, since the whole claim is that the
agent is swappable without touching the boundary.
"""

import subprocess
import sys

from sandbox_runner import _run_script, _task_md


def test_run_script_is_self_contained():
    s = _run_script(owner="acme", repo="app", issue=5, branch="agent/issue-5", token="TKN123")
    # Env set INSIDE the script (no reliance on a shell env-prefix or passthrough).
    assert "export HOME=/app" in s
    assert 'export GITEA_TOKEN="TKN123"' in s
    assert "export MODEL_BASE_URL=" in s
    assert 'export MODEL_MAIN="local-smart"' in s


def test_run_script_clone_and_branch():
    s = _run_script(owner="acme", repo="app", issue=5, branch="agent/issue-5", token="T")
    assert "git clone http://gitea-http.gitea.svc.cluster.local:3000/acme/app.git repo" in s
    assert "git checkout -b agent/issue-5" in s


def test_run_script_credentials_and_push_guard():
    s = _run_script(owner="acme", repo="app", issue=5, branch="b", token="T")
    assert "credential.helper store" in s
    assert '"$HOME/.git-credentials"' in s
    # Push + PR only happen when the branch advanced past the base commit
    # (no stray empty branches).
    assert '"$(git rev-parse HEAD)" != "$BASE_SHA"' in s


def test_run_script_invokes_the_agent_through_the_swappable_seam():
    s = _run_script(owner="acme", repo="app", issue=5, branch="b", token="T")
    # The agent is ONE line, and it is a path into the sandbox image. Nothing
    # about which agent is running leaks into the wrapper.
    assert "bash /opt/agents/claude.sh" in s


def test_the_agent_never_sees_the_push_or_pr_credential():
    """The load-bearing security property, asserted mechanically: the agent
    invocation happens BEFORE the push, and the push/PR lines are the wrapper's."""
    s = _run_script(owner="acme", repo="app", issue=5, branch="b", token="T")
    agent_at = s.index("/opt/agents/")
    push_at = s.index("git push -u origin")
    pr_at = s.index("/api/v1/repos/acme/app/pulls")
    assert agent_at < push_at < pr_at
    # The agent is invoked with no token on its command line and no token in a
    # variable it is told about; GITEA_TOKEN is exported for the wrapper's own
    # git and curl. (It is in the process environment — see the README's honest
    # note on what that does and does not buy.)
    agent_line = [ln for ln in s.splitlines() if "/opt/agents/" in ln][0]
    assert "GITEA_TOKEN" not in agent_line
    assert "TOKENVALUE" not in _run_script(
        owner="acme", repo="app", issue=5, branch="b", token="TOKENVALUE"
    ).splitlines()[[i for i, ln in enumerate(s.splitlines()) if "/opt/agents/" in ln][0]]


def test_run_script_streams_to_pod_log():
    s = _run_script(owner="acme", repo="app", issue=5, branch="b", token="T")
    # Mirror the whole run to PID 1's stdout (= the pod log) so kubectl logs -f
    # shows it live.
    assert "tee /proc/1/fd/1" in s


def test_task_md_carries_issue_context():
    m = _task_md(owner="acme", repo="app", issue=9, branch="b", title="Add health", body="Return ok")
    assert "issue #9" in m
    assert "Add health" in m
    assert "Return ok" in m


def test_task_md_tells_the_agent_the_pr_is_not_its_job():
    m = _task_md(owner="acme", repo="app", issue=9, branch="b", title="t", body="b")
    assert "Do NOT push or open a PR yourself" in m


def test_stream_filter_renders_events_and_survives_garbage():
    """The renderer now lives in the sandbox image (agents/stream_filter.py), so
    the test reaches across to it there rather than importing a string constant."""
    import json
    import pathlib

    filt = (pathlib.Path(__file__).resolve().parents[1]
            / "coding-runtime-sandbox" / "agents" / "stream_filter.py")
    events = "\n".join([
        json.dumps({"type": "system", "subtype": "init", "model": "local-smart"}),
        "not json at all",
        json.dumps({"type": "assistant", "message": {"content": [
            {"type": "text", "text": "Reading the repo."},
            {"type": "tool_use", "name": "Edit", "input": {"file_path": "/app/repo/app.py"}},
        ]}}),
        json.dumps({"type": "result", "subtype": "success", "num_turns": 7}),
    ])
    out = subprocess.run([sys.executable, str(filt)],
                         input=events, capture_output=True, text=True, timeout=30)
    assert out.returncode == 0
    assert "[claude] session start (model local-smart)" in out.stdout
    assert "[claude] Reading the repo." in out.stdout
    assert "[claude] tool Edit: /app/repo/app.py" in out.stdout
    assert "[claude] done: success (7 turns)" in out.stdout
