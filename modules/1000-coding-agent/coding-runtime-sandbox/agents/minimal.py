"""A deliberately minimal coding agent — the fallback implementation.

Roughly 150 lines: a tool-calling loop with three tools (list_files, read_file,
write_file) against the SAME model path Claude Code uses, the AI gateway's
Anthropic Messages route. It is not a good coding agent and is not trying to be.
It exists so that labs 6-7 can be demonstrated end to end on a model that cannot
drive Claude Code, because the thing labs 6-7 teach is the trust boundary around
the agent, and that boundary is identical whichever binary runs inside it:

  - it holds no cloud credential
  - it holds no Kubernetes service-account token
  - it can reach exactly the model gateway and Gitea, and nothing else
  - it commits; it does NOT hold the credential that pushes or opens the PR

Contract (identical for every script in /opt/agents/):
  in:  $HOME/task.md, cwd = the cloned repo on a fresh branch
  env: MODEL_BASE_URL (…/anthropic), MODEL_MAIN
  out: the work COMMITTED on the current branch. Never push. Never open a PR.
"""

import json
import os
import pathlib
import subprocess
import sys

import httpx

BASE_URL = os.environ["MODEL_BASE_URL"].rstrip("/")
MODEL = os.environ.get("MODEL_MAIN", "local-smart")
MAX_TOKENS = int(os.environ.get("MODEL_MAX_TOKENS", "6144"))
# ADR 0007's lesson applied to a different tool: write_file's argument is an
# entire source file, the largest tool argument in this repo, and qwen3 spends
# its budget on reasoning BEFORE it emits the call. A budget adequate for a tool
# catalogue is not adequate for the next tool added to it.
MAX_TURNS = int(os.environ.get("AGENT_MAX_TURNS", "12"))
REPO = pathlib.Path.cwd()

TOOLS = [
    {
        "name": "list_files",
        "description": "List the files tracked in the repository.",
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "read_file",
        "description": "Read one file from the repository.",
        "input_schema": {
            "type": "object",
            "properties": {"path": {"type": "string"}},
            "required": ["path"],
        },
    },
    {
        "name": "write_file",
        "description": "Write one file in the repository, replacing it entirely.",
        "input_schema": {
            "type": "object",
            "properties": {"path": {"type": "string"}, "content": {"type": "string"}},
            "required": ["path", "content"],
        },
    },
]

SYSTEM = """You are a coding agent working inside a git repository.
Use the tools to inspect the repo and to write files. Write COMPLETE file
contents — write_file replaces the whole file. Keep the change minimal and
correct, and update or add a test for it. When the change is done, reply with a
one-line summary and no tool call. Do not attempt to run commands, push, or open
a pull request: a wrapper outside your sandbox does that."""


def safe_path(rel: str) -> pathlib.Path:
    """Confine every tool to the checkout. The model is untrusted input; the
    sandbox is the real boundary, but a path check costs nothing and keeps a
    confused agent from scribbling on the git credential file next door.

    Absolute paths are accepted when they already point inside the checkout. The
    first version of this function did `REPO / rel.lstrip("/")` unconditionally,
    and the model — reasonably — answered `/app/repo/app.py`, which became
    `/app/repo/app/repo/app.py`. The run still produced a PR; the PR body carried
    a pytest collection error; a human read it. That is the loop working, but the
    loop should not have to absorb this.
    """
    root = REPO.resolve()
    candidate = pathlib.Path(rel)
    target = candidate.resolve() if candidate.is_absolute() else (root / rel).resolve()
    if target != root and root not in target.parents:
        raise ValueError("path escapes the repository: %s" % rel)
    return target


def run_tool(name: str, args: dict) -> str:
    if name == "list_files":
        out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, cwd=REPO)
        return out.stdout or "(empty)"
    if name == "read_file":
        path = safe_path(args["path"])
        if not path.is_file():
            return "ERROR: no such file: %s" % args["path"]
        return path.read_text()[:20000]
    if name == "write_file":
        path = safe_path(args["path"])
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(args["content"])
        print("[minimal] wrote %s (%d bytes)" % (args["path"], len(args["content"])), flush=True)
        return "wrote %s" % args["path"]
    return "ERROR: unknown tool %s" % name


def call_model(client: httpx.Client, messages: list) -> dict:
    resp = client.post(
        BASE_URL + "/v1/messages",
        headers={
            "content-type": "application/json",
            "anthropic-version": "2023-06-01",
            # The gateway holds whatever model credential exists. The agent has
            # none, and needs none — exactly as in lab 0.
            "x-api-key": "not-needed",
        },
        json={
            "model": MODEL,
            "max_tokens": MAX_TOKENS,
            "system": SYSTEM,
            "tools": TOOLS,
            "messages": messages,
        },
        timeout=600,
    )
    resp.raise_for_status()
    return resp.json()


def main() -> int:
    task = (pathlib.Path(os.environ["HOME"]) / "task.md").read_text()
    messages = [{"role": "user", "content": task}]
    wrote_anything = False

    with httpx.Client() as client:
        for turn in range(1, MAX_TURNS + 1):
            reply = call_model(client, messages)
            blocks = reply.get("content") or []
            tool_uses = [b for b in blocks if b.get("type") == "tool_use"]
            for block in blocks:
                if block.get("type") == "text" and block.get("text", "").strip():
                    for line in block["text"].strip().splitlines():
                        print("[minimal] %s" % line, flush=True)
            if not tool_uses:
                print("[minimal] done: no further tool calls (%d turns)" % turn, flush=True)
                break
            messages.append({"role": "assistant", "content": blocks})
            results = []
            for use in tool_uses:
                print("[minimal] tool %s %s" % (use["name"], json.dumps(use.get("input", {}))[:120]), flush=True)
                try:
                    output = run_tool(use["name"], use.get("input") or {})
                    wrote_anything = wrote_anything or use["name"] == "write_file"
                except Exception as exc:  # surfaced to the model, not fatal
                    output = "ERROR: %s" % exc
                results.append({"type": "tool_result", "tool_use_id": use["id"], "content": output})
            messages.append({"role": "user", "content": results})
        else:
            print("[minimal] stopped at the %d-turn cap" % MAX_TURNS, flush=True)

    if not wrote_anything:
        print("[minimal] the model wrote no files", flush=True)
        return 0

    # Commit. The agent's authority ends here: it has no push credential and no
    # PR-opening credential. The wrapper decides whether this commit becomes a
    # branch and a pull request.
    subprocess.run(["git", "add", "-A"], cwd=REPO, check=True)
    subprocess.run(
        ["git", "commit", "-m", os.environ.get("AGENT_COMMIT_MESSAGE", "automated change")],
        cwd=REPO,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
