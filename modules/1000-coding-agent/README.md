# Labs 6-7 — Autonomous coding agent (git issue → sandbox → pull request)

A labelled issue on an in-cluster Gitea repo triggers a dispatcher, which runs a coding agent inside a per-execution gVisor sandbox. The agent implements the change and commits. **The wrapper**, not the agent, pushes the branch and opens the PR. A human reviews it.

Local port of the workshop's module 1000. `server.py`, `webhook.py` and `gitea_client.py` are **copied verbatim**; `sandbox_runner.py` differs in three lines of configuration and one change of design (below).

## The flow

```
human  → Gitea: file an issue, add the `agent` label
Gitea  → coding-agent-dispatcher (in-cluster webhook, HMAC-verified)
dispatcher: mint a per-run Gitea token; claim a gvisor-coding sandbox
dispatcher → sandbox (SDK files.write): run.sh + task.md   [out-of-band, never via the model]
sandbox:   clone → AGENT edits and commits → wrapper pushes → wrapper runs pytest → wrapper opens the PR
           model calls → Envoy AI Gateway /anthropic/v1/messages → alias table → a model
dispatcher: find the PR → comment the link on the issue → terminate the sandbox → REVOKE the token
human:     reviews the PR
```

## The four limits, and where each one lives

The workshop states four limits, and none of them is "trust the model".

| # | Limit | Where it is enforced | How to check it |
|---|---|---|---|
| 1 | **No human PAT anywhere** | `platform/gitea/provision.sh` creates a bot account; the only stored credential is the bot's password in Secret `coding-agent-creds` | `kubectl get secret coding-agent-creds -o jsonpath='{.data}'` — bot username/password, webhook secret, repo coordinates. No human's token exists to leak. |
| 2 | **No standing credentials in the sandbox** | `gitea_client.mint_token` before the run, `revoke_token` in a `finally` after it; no cloud key is ever written | `make coding-token-check` |
| 3 | **Egress locked to exactly two in-cluster services** | `platform/sandbox/sandbox-coding-egress-networkpolicy.yaml` | `make coding-egress-check` |
| 4 | **Untrusted model-written code runs in the sandbox runtime** | `platform/sandbox/sandboxtemplate-gvisor-coding.yaml`: `runtimeClassName: gvisor`, `automountServiceAccountToken: false` | `make coding-egress-check` prints the sandbox kernel and the absence of the SA token dir |

Plus the one that ties them together: **the wrapper holds the push credential, the agent does not.** `task.md` tells the agent to commit and not to push — but that instruction is a courtesy, not a control. The agent could not push if it tried; `GITEA_TOKEN` and the `git push` line live in `run.sh`, which runs after the agent has exited. **The PR is the human-in-the-loop boundary, and the agent's job ends there.**

## The agent is a command

The workshop hardcodes `claude -p` into the generated `run.sh`. Here `run.sh` invokes one line:

```bash
bash /opt/agents/$CODING_AGENT.sh
```

`/opt/agents/` lives in the sandbox image. Each script there is a complete coding agent with the same contract: **`task.md` in, a commit on the current branch out, and no push credential ever in its hands.** Two ship today:

| `CODING_AGENT` | What it is | Needs |
|---|---|---|
| `claude` | Anthropic's Claude Code CLI, headless, unpatched. The workshop's own agent. | a model that can drive its tool protocol — `remote-smart` does, `local-smart` does not |
| `minimal` | ~150 lines: a tool-calling loop with `list_files` / `read_file` / `write_file` against the same model path | nothing external; works on the local 8B model |

Swapping is one environment variable on the dispatcher Deployment. That is not decoration: the point of labs 6-7 is the boundary *around* the agent, so the agent has to be the piece that can be replaced without touching the boundary. The dispatcher's unit tests assert the seam rather than the binary — `test_the_agent_never_sees_the_push_or_pr_credential` checks the ordering, not the string `claude`.

## Which agent this repo runs, and why

**`claude` against `remote-smart` (Claude Code, OpenRouter free tier through the gateway).** This is the workshop's real agent doing the workshop's real job. Verified end to end: issue #3 produced PR #4 with a correct `/version` endpoint, a matching test, and `2 passed` in the PR body.

The path there is worth recording, because two of the three obstacles were not where they looked:

1. **There is no Anthropic credential on this machine.** Claude Code does not need one when `ANTHROPIC_BASE_URL` points elsewhere and `ANTHROPIC_AUTH_TOKEN` is set to anything — verified: it reports `apiKeySource: ANTHROPIC_API_KEY` and never attempts a login.
2. **Envoy AI Gateway v1.0 translates Anthropic-format requests to an OpenAI backend by itself**, including streaming and `tool_use`. No translating proxy (claudish or similar) is needed, and adding one would introduce a component that has to hold the model key. See [ADR 0009](../../docs/adr/0009-coding-agent-is-a-swappable-command.md).
3. **The blocker was a 32 KiB buffer.** Claude Code's first request carries ~20 tool schemas; Envoy Gateway's default `connection.bufferLimit` rejected it with a 413 that Claude Code renders as *"Request too large (max 32MB). Accumulated images and attachments…"* — no images, and the limit is 32 KiB, not 32 MB. `platform/gateway/client-traffic-policy-buffer.yaml`.

`minimal` remains the no-credential fallback: with `CODING_AGENT=minimal` and `MODEL_MAIN=local-smart` the whole lab runs on Ollama with no account anywhere. It produced a working PR too (issue #1 → PR #2), and its first run also produced a *bad* one, which is instructive — see the ADR.

## Where the model key lives

With `remote-*`, the OpenRouter key is read **by the gateway**, from a Kubernetes Secret, at the cluster edge. The sandbox never holds it and cannot reach OpenRouter: `make coding-egress-check` shows `openrouter.ai:443` blocked from inside a claimed sandbox while the model calls succeed through the in-cluster gateway. That is limit #2 holding while the model moves off the laptop — the same secretless-at-the-gateway property lab 0 demonstrates for the Bedrock hop, arriving a second time.

## Running it

```bash
make gitea            # Gitea + bot + seed repo + label + webhook (prints logins)
make coding           # everything: platform, images, dispatcher
make gitea-ui         # http://127.0.0.1:3001/ in another shell

# optional, for the Claude Code agent:
printf '%s' 'sk-or-v1-...' > .secrets/openrouter.key
make model-key model-remote model-remote-test

make coding-issue TITLE="Add a /health endpoint" BODY="Return {\"status\": \"ok\"}."
make coding-watch     # dispatcher + sandbox logs
make coding-show N=1
```

Verification:

```bash
make coding-unit            # 22 tests, no cluster
make coding-egress-check    # limits 3 and 4, from a CLAIMED sandbox, with a control
make coding-token-check     # limit 2: mint -> 200 -> revoke -> 401 + residue check
```

## What is degraded versus the workshop

- **gVisor, not Kata + Firecracker.** Unchanged from lab 5 — see [ADR 0005](../../docs/adr/0005-gvisor-not-kata-firecracker.md). "A process that escapes the container escapes into a VM" is not true here.
- **A free hosted model, not Claude on Bedrock.** The agent is the same binary and the wire path is the same shape; the model is weaker and rate-limited. Rate limits are left to fail visibly rather than papered over with retries.
- **Gitea is a plain Deployment, not the Helm chart, and has no HTTPS front door.** A human reaches it by port-forward. Nothing the lab teaches depends on the CloudFront/ALB hop.
