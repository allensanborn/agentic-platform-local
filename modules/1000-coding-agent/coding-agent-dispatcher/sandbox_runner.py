"""Vend a coding sandbox, inject creds + task, run the coding agent, terminate.

Local port of the workshop's sandbox_runner.py. The dispatcher (server.py) calls
run_coding_task(...) after minting a per-run token. Creds + task are injected as
FILES, out-of-band — they are never routed through the model, never appear in a
prompt, and never appear in any tool result. The sandbox holds no cloud
credential and no Kubernetes service-account token, and its egress is locked to
the AI gateway plus Gitea. This process, not the sandbox, holds the SandboxClaim
RBAC.

Three things differ from the workshop, and only the third is a change of design:

  1. WARMPOOL is `gvisor-coding-pool`, not `kata-fc-coding-pool` (ADR 0005).
  2. The model aliases are the local ones. The URL shape is unchanged — still the
     Envoy AI Gateway's `/anthropic` route — because Envoy AI Gateway v1.0
     translates the Anthropic Messages wire format to whatever the backend
     speaks, and it turns out that includes a self-hosted OpenAI backend, not
     only Bedrock (ADR 0009).
  3. THE AGENT IS A COMMAND, selected by CODING_AGENT. The workshop hardcodes
     `claude -p` into the generated run.sh. Here run.sh invokes
     `bash /opt/agents/$CODING_AGENT.sh`, a script baked into the sandbox image
     whose contract is "task.md in, a commit on the current branch out". Swapping
     the coding agent is one environment variable on the dispatcher Deployment.
     This is not gold-plating: the whole point of labs 6-7 is the trust boundary
     AROUND the agent, so the agent has to be the part that can be replaced
     without touching the boundary.

The sandbox runtime's /execute runs `shlex.split(cmd)` + subprocess with NO shell
and NO env passthrough, so ALL environment setup (HOME, GITEA_TOKEN, model vars)
must live INSIDE run.sh — the command we send is just `bash /app/run.sh`.
"""

import logging
import os

ROUTER_URL = os.environ.get(
    "SANDBOX_ROUTER_URL",
    "http://sandbox-router-svc.agent-sandbox-system.svc.cluster.local:8080",
)
WARMPOOL = os.environ.get("SANDBOX_WARMPOOL", "gvisor-coding-pool")
SANDBOX_NAMESPACE = os.environ.get("SANDBOX_NAMESPACE", "agent-sandbox")
RUN_TIMEOUT_SECONDS = int(os.environ.get("SANDBOX_RUN_TIMEOUT", "1500"))
READY_TIMEOUT_SECONDS = int(os.environ.get("SANDBOX_READY_TIMEOUT", "300"))
SHUTDOWN_AFTER_SECONDS = int(os.environ.get("SANDBOX_SHUTDOWN_AFTER", "1800"))

# In-cluster endpoints injected into the sandbox. These two hostnames are the
# ENTIRE reachable world from inside a coding sandbox; see
# platform/sandbox/sandbox-coding-egress-networkpolicy.yaml.
GITEA_INTERNAL = os.environ.get("GITEA_INTERNAL_URL", "http://gitea-http.gitea.svc.cluster.local:3000")
MODEL_BASE_URL = os.environ.get(
    "MODEL_BASE_URL", "http://ai-gateway.envoy-gateway-system.svc.cluster.local/anthropic"
)
MODEL_MAIN = os.environ.get("MODEL_MAIN", "local-smart")
MODEL_SMALL = os.environ.get("MODEL_SMALL", "local-fast")
MODEL_MAX_TOKENS = os.environ.get("MODEL_MAX_TOKENS", "6144")

# Which script in the sandbox image's /opt/agents/ is the coding agent.
CODING_AGENT = os.environ.get("CODING_AGENT", "claude")

MAX_OUTPUT_BYTES = 64 * 1024


def cap_output(text: str | None) -> str:
    if not text:
        return ""
    data = text.encode("utf-8")
    if len(data) <= MAX_OUTPUT_BYTES:
        return text
    return data[:MAX_OUTPUT_BYTES].decode("utf-8", errors="ignore") + "...[truncated]"


def _run_script(*, owner: str, repo: str, issue: int, branch: str, token: str) -> str:
    """The bash the sandbox executes — the WRAPPER, and the reason the trust
    boundary holds. Read it as a division of authority:

      the wrapper holds  the git push credential, and pushes
      the wrapper holds  the PR-opening credential, and opens the PR
      the AGENT holds    neither, and is told in task.md not to try

    So the worst a compromised or confused model can do is write a commit on a
    throwaway branch inside a sandbox that is about to be destroyed. Publishing
    that commit is a decision made by code the model never touched, and merging
    it is a decision made by a human on a pull request. THE PR IS THE
    HUMAN-IN-THE-LOOP BOUNDARY; the agent's job ends there.

    Self-contained by necessity: the runtime runs it with no shell and no env
    passthrough, so it exports its own HOME, GITEA_TOKEN and model env. A GLOBAL
    gitignore is configured before the clone so build/test artifacts
    (__pycache__, *.pyc, .pytest_cache) are never staged by `git add -A`, even
    when the target repo ships no .gitignore.
    """
    host = GITEA_INTERNAL.split("://", 1)[1]  # gitea-http...:3000
    scheme = GITEA_INTERNAL.split("://", 1)[0]
    return f"""set -euo pipefail
# Mirror this script's stdout to PID 1's stdout (the runtime server), which IS
# the pod log — so `kubectl logs -f` on the sandbox shows the run live. tee's own
# stdout still flows back to the runtime's command capture, so the dispatcher's
# transcript (result.stdout) is unchanged by this.
exec > >(tee /proc/1/fd/1)
export HOME=/app
export GITEA_TOKEN="{token}"
export MODEL_BASE_URL="{MODEL_BASE_URL}"
export MODEL_MAIN="{MODEL_MAIN}"
export MODEL_SMALL="{MODEL_SMALL}"
export MODEL_MAX_TOKENS="{MODEL_MAX_TOKENS}"
export AGENT_COMMIT_MESSAGE="{branch}: automated change for issue #{issue}"
git config --global user.email "coding-agent-bot@example.com"
git config --global user.name "coding-agent-bot"
git config --global credential.helper store
printf '__pycache__/\\n*.py[cod]\\n.pytest_cache/\\n.venv/\\n' > "$HOME/.gitignore_global"
git config --global core.excludesFile "$HOME/.gitignore_global"
printf '{scheme}://coding-agent-bot:%s@{host}\\n' "$GITEA_TOKEN" > "$HOME/.git-credentials"
cd /app
git clone {scheme}://{host}/{owner}/{repo}.git repo
cd repo
git checkout -b {branch}
BASE_SHA=$(git rev-parse HEAD)
# THE INTERCHANGEABLE PART. Everything above and below this line is the trust
# boundary; this one line is the coding agent. `|| true` because an agent that
# crashes should still fall through to the push gate, which is what actually
# decides whether anything happened.
bash /opt/agents/{CODING_AGENT}.sh || true
# Commit anything the agent left uncommitted. Best-effort: an agent that made its
# own commit leaves this with nothing to do, and the push gate below (branch
# advanced past BASE_SHA) is true either way.
git add -A
git commit -m "$AGENT_COMMIT_MESSAGE" || true
if [ "$(git rev-parse HEAD)" != "$BASE_SHA" ]; then
  git push -u origin {branch}
  # Run the repo's tests (deps are pre-baked in the image; the sandbox egress is
  # locked so `pip install` cannot reach PyPI). Capture the summary for the PR
  # body. Non-fatal: a failing/absent suite still opens the PR, flagged as such —
  # a human reads the result on the PR, which is the point.
  set +e
  pytest -q > /app/pytest.txt 2>&1
  TEST_RC=$?
  set -e
  if [ "$TEST_RC" -eq 0 ]; then TEST_HDR="### Tests passed"
  elif [ "$TEST_RC" -eq 5 ]; then TEST_HDR="### No tests collected"
  else TEST_HDR="### Tests FAILED (pytest exit $TEST_RC)"; fi
  {{
    echo "Automated PR for issue #{issue}, written by the coding agent in an isolated sandbox."
    echo
    echo "$TEST_HDR"
    echo
    echo '```'
    tail -n 30 /app/pytest.txt
    echo '```'
  }} > /app/prbody.md
  # Build the JSON body with Python so arbitrary pytest output is safely escaped.
  BODY=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' < /app/prbody.md)
  curl -sS -X POST "{GITEA_INTERNAL}/api/v1/repos/{owner}/{repo}/pulls" \
    -H "Authorization: token $GITEA_TOKEN" -H "content-type: application/json" \
    -d "{{\\"head\\":\\"{branch}\\",\\"base\\":\\"main\\",\\"title\\":\\"Fix issue #{issue}\\",\\"body\\":$BODY}}" || true
else
  echo "no changes to commit; skipping push and PR"
fi
"""


def _task_md(*, owner: str, repo: str, issue: int, branch: str, title: str, body: str) -> str:
    """The prompt. Note the last instruction: the agent is told not to push or
    open a PR. That instruction is a courtesy, not a control — the agent could
    not push if it tried, because the push credential lives in the wrapper's
    environment and not in the agent's. Saying it out loud stops the agent
    wasting turns discovering that."""
    return f"""# Task (from issue #{issue}: {title})

{body}

## Instructions
- You are on a fresh branch `{branch}` inside the cloned repo at /app/repo.
- Implement the change described above. Keep it minimal and correct.
- Add or update unit tests covering your change, and run them to confirm they
  pass (`pytest` is available offline).
- Commit your work with a clear message.
- Do NOT push or open a PR yourself: the wrapper pushes the branch, runs the test
  suite, and opens the PR with the test summary in its description.
"""


def run_coding_task(*, owner: str, repo: str, issue: int, title: str, body: str, token: str) -> dict:
    """Clone the repo in a fresh coding sandbox, run the coding agent, push a
    branch + PR. Returns {stdout, stderr, exit_code, branch}. Always terminates
    the sandbox — single-use is the point, and the `finally` is what makes the
    per-run token's blast radius end with the run."""
    # Imported lazily so the pure script builders (_run_script/_task_md) are
    # unit-testable without the SDK installed.
    from k8s_agent_sandbox import SandboxClient
    from k8s_agent_sandbox.models import SandboxDirectConnectionConfig

    branch = f"agent/issue-{issue}"
    client = SandboxClient(
        connection_config=SandboxDirectConnectionConfig(api_url=ROUTER_URL, server_port=8888),
    )
    sandbox = client.create_sandbox(
        warmpool=WARMPOOL,
        namespace=SANDBOX_NAMESPACE,
        sandbox_ready_timeout=READY_TIMEOUT_SECONDS,
        shutdown_after_seconds=SHUTDOWN_AFTER_SECONDS,
    )
    try:
        sandbox.files.write("task.md", _task_md(owner=owner, repo=repo, issue=issue,
                                                branch=branch, title=title, body=body), timeout=60)
        sandbox.files.write("run.sh", _run_script(owner=owner, repo=repo, issue=issue,
                                                  branch=branch, token=token), timeout=60)
        # The runtime has no shell/env passthrough, so run.sh is self-contained
        # and the command is just `bash /app/run.sh` (splits cleanly under shlex).
        result = sandbox.commands.run("bash /app/run.sh", timeout=RUN_TIMEOUT_SECONDS)
        return {
            "stdout": cap_output(result.stdout),
            "stderr": cap_output(result.stderr),
            "exit_code": result.exit_code,
            "branch": branch,
        }
    finally:
        try:
            sandbox.terminate()
        except Exception:
            logging.exception("sandbox terminate failed (TTL backstop will GC)")
