# Coding sandbox runtime: the agent-sandbox SDK-contract server (:8888,
# /execute + /upload — main.py is byte-identical to lab 5's) PLUS git, Node, and
# the coding agents themselves.
#
# Local port of the workshop's coding-runtime-sandbox/Dockerfile. Differences:
#   - base is docker.io python:3.11-slim, not the ECR public mirror (no AWS here)
#   - /opt/agents/ ships MORE THAN ONE agent implementation. The workshop hardcodes
#     `claude -p`; this image installs the Claude Code CLI the same way AND a
#     minimal tool-calling agent, and the dispatcher picks between them with one
#     environment variable. See modules/1000-coding-agent/README.md for why.
FROM python:3.11-slim
WORKDIR /app

# git + curl + Node + npm for the Claude Code CLI. Installed from Debian's own
# repos rather than the NodeSource apt repo, for the reason the workshop found
# the hard way: NodeSource's setup script exits 0 even when its signing-key fetch
# fails, so the build silently falls back to Debian's nodejs WITHOUT npm and then
# dies at `npm install -g` with "npm: not found". Debian trixie ships nodejs 20 +
# npm. Claude Code prints an EBADENGINE warning (it prefers Node >= 22) and runs.
# curl stays: the wrapper uses it to open the PR through the Gitea API.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates nodejs npm && \
    npm install -g @anthropic-ai/claude-code && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
# The interchangeable part. Each script in here is a complete coding agent: it
# is handed /app/task.md and a checked-out repo at /app/repo, and its contract is
# to leave the work COMMITTED on the current branch. None of them ever sees a git
# push credential — that stays with the wrapper (limit: the model does not hold
# the credential that publishes its output).
COPY agents/ /opt/agents/
RUN chmod +x /opt/agents/*.sh && chown -R 1000:1000 /app
# UID 1000 has no passwd home; point HOME at the writable workdir so git config,
# ~/.git-credentials and Claude Code's ~/.claude all work. The runtime's /execute
# passes no env, so the subprocess inherits this.
ENV HOME=/app
USER 1000
EXPOSE 8888
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8888", "--log-level", "info"]
