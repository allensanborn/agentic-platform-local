# ADR 0009 — the coding agent is a swappable command, and the gateway is the compatibility layer

**Status:** accepted
**Date:** 2026-08-16

## Context

Labs 6-7 run a coding agent inside a sandbox. The workshop's agent is Anthropic's Claude Code CLI, invoked as `claude -p`, talking to Claude-on-Bedrock through the Envoy AI Gateway's Anthropic route.

This machine has no Anthropic credential: no `ANTHROPIC_API_KEY`, no `ANTHROPIC_AUTH_TOKEN`, no `~/.claude/.credentials.json`. Reproducing the lab therefore required answering a question the workshop never has to ask — what, exactly, is the agent binary, and how much of the lab depends on it being that particular one?

## Decision

Two decisions, and the second is what makes the first cheap.

**1. `run.sh` invokes `bash /opt/agents/$CODING_AGENT.sh`, one line, selected by an environment variable on the dispatcher Deployment.** Each script in the sandbox image's `/opt/agents/` is a complete coding agent with a fixed contract: `task.md` in, a commit on the current branch out, and no push credential in its hands. Two ship: `claude` (Claude Code, unpatched) and `minimal` (~150 lines of tool-calling loop).

**2. The compatibility layer is the AI gateway, not a proxy beside it.** Envoy AI Gateway v1.0 accepts the Anthropic Messages wire format on `/anthropic/v1/messages` and translates it to whatever the backend speaks. This is documented for Bedrock; it was not obvious that it works against an arbitrary self-hosted OpenAI backend. It does, and it was verified before anything was built on it:

```
$ curl .../anthropic/v1/messages -d '{"model":"local-fast","max_tokens":32,"messages":[...]}'
{"type":"message","content":[{"type":"text","text":"Hello, I'm here."}],"model":"llama3.2:1b",...}

# streaming: message_start / content_block_delta / message_stop, correct Anthropic SSE
# tool_use:  {"type":"tool_use","name":"Write","input":{"file_path":"hello.txt","content":"banana"}}
```

So no translating sidecar (claudish and similar) is needed. That matters beyond tidiness: a translating proxy is a component that has to hold the model credential, and the gateway already holds it. Keeping the translation in the gateway keeps the key at the cluster edge, which is the property lab 0 exists to demonstrate.

## What actually runs, and why

**`CODING_AGENT=claude`, `MODEL_MAIN=remote-smart`** — the workshop's real agent, driven by a free OpenRouter model through the gateway's alias table. Verified end to end: issue #3 → PR #4, a correct `/version` endpoint, a matching test, `2 passed` in the PR body.

Three obstacles stood in the way and only one of them was the model.

**Claude Code does not need an Anthropic account.** With `ANTHROPIC_BASE_URL` pointed at the gateway and `ANTHROPIC_AUTH_TOKEN` set to any placeholder, it reports `apiKeySource: ANTHROPIC_API_KEY` and never attempts a login. This was the assumption most worth testing and it turned out to be false in the helpful direction.

**The real blocker was a 32 KiB buffer.** Claude Code's first request carries its system prompt and ~20 tool schemas, and the AI Gateway's ext_proc filter must buffer the whole body to translate it. Envoy Gateway's default `connection.bufferLimit` is 32 KiB, so the request was rejected before reaching any model. What it looked like from inside the sandbox:

```
[claude-code:unrecognized_model] {"model":"local-smart","query_source":"sdk"}
Request too large (max 32MB). Accumulated images and attachments in the
conversation pushed the request over the limit.
```

Neither sentence is true. There are no images and no attachments; the limit is 32 KiB, not 32 MB; the model is fine. Claude Code is rendering a bare HTTP 413 through its own error vocabulary, and the more prominent line blames the model. Located by ignoring both messages and measuring the gateway directly with synthetic bodies — 8 KB → 200, 32 KB → 413. Fixed by `platform/gateway/client-traffic-policy-buffer.yaml`.

**qwen3:8b cannot drive Claude Code.** With the plumbing correct, the local model still failed: asked to create a file, it emitted a rambling essay about filesystem permissions and a malformed `Write "/banana.txt.tmp..."`. The same model drives the `minimal` agent's three-tool loop correctly. This is a capability wall, not a wiring problem, and it is the one that justifies the whole swappable-agent structure.

## Consequences

### The lab survives the agent being replaced, which is the actual claim

`minimal` is not a consolation prize. Run it with `MODEL_MAIN=local-smart` and the entire lab holds with no account anywhere on the machine: the per-run token is still minted and revoked, the egress is still locked to two services, the sandbox still has no service-account token, the wrapper still holds the push credential, and the PR is still where a human enters. Every one of the four limits is a property of the boundary, and none of them is a property of which binary sits inside it. That is the lab's thesis stated as an experiment rather than an assertion, and it now has a result.

### Swapping the model is an edit to the alias table, and labs 6-7 are where that pays

Lab 0 demonstrates `local-fast → llama3.2:1b` as a demo. Here the same mechanism does real work: `platform/gateway/openrouter.yaml` adds a backend and two aliases, and `MODEL_MAIN=remote-smart` moves the coding agent from an 8B model on the laptop to a 120B model in someone else's datacenter. No agent code, no image rebuild, no dispatcher change. The sandbox's egress allowlist does not change either — it still reaches exactly the in-cluster gateway and Gitea, and `make coding-egress-check` confirms `openrouter.ai:443` is blocked from inside a claimed sandbox while the model calls succeed.

### A bad PR is a working system

The `minimal` agent's first end-to-end run wrote `app/repo/app.py` instead of `app.py`: the model answered `/app/repo/app.py`, an absolute path, and `safe_path` did `REPO / rel.lstrip("/")`. The run still pushed, still ran pytest, still opened the PR, and the PR body carried the collection error. Nobody had to go looking. The bug is fixed, but the episode is the argument for the boundary: the agent produced wrong output and the worst consequence was a pull request a human declined to merge.

### Two facts about k3s that the workshop's manifests cannot carry

**Egress policy is evaluated after DNAT.** kube-router sees the destination *pod* IP and the *pod* port, so the workshop's service-CIDR `ipBlock` escape hatch is unnecessary here — and dropping it is a tightening, since on the workshop's CNI that ipBlock permits any ClusterIP on the listed port. But the port must be the target port: the AI gateway's Service is `80 → targetPort 10080`, and a rule allowing only 80 silently blocked the model path while Gitea (`3000 → 3000`) worked. An allow rule that matches nothing is indistinguishable from a deny, which is ADR 0006's lesson arriving from the positive direction — the control has to include the cases that must *succeed*, not only the ones that must fail.

**k3s's Traefik owns the Gateway API CRDs, and Envoy Gateway cannot see `BackendTLSPolicy`.** Traefik's chart installs bundle v1.4.0, which serves only `v1`; Envoy Gateway v1.5.6 watches `v1alpha3` and logs `BackendTLSPolicy CRD not found, skipping BackendTLSPolicy watch`. Forcing `served: true` on the `v1alpha3` entry and restarting the controller does not change the message. Consequence: the gateway cannot originate TLS to a hosted provider, and dials `openrouter.ai:443` in cleartext (`400 The plain HTTP request was sent to HTTPS port`). The workaround is one nginx doing TLS origination inside the cluster (`platform/gateway/openrouter-tls-proxy.yaml`). It does not move the credential — the gateway still injects it — but the key and body cross one in-cluster hop in cleartext, and that is a real cost that should not be copied to a multi-tenant cluster.

### Small things that cost real time

- `SandboxClaim` reports its bound sandbox at `.status.sandbox.name`. `.status.sandboxName` yields an empty string, and a script that reads it reports "claim never bound" for a claim that bound in under a second.
- `AIServiceBackend.spec.schema.prefix` **replaces** the version segment rather than prepending to it. OpenRouter needs `prefix: /api/v1`; `prefix: /api` produces `POST /api/chat/completions` and a 404.
- nginx reads the response *header* into a `proxy_buffer_size` buffer even with `proxy_buffering off`. OpenRouter's headers exceed the 4k default, and the result is a bare 502 whose only explanation is in the proxy's own log.
- `set -o pipefail` plus `tr -dc … </dev/urandom | head -c N` is a silent whole-script abort: `head` exits first, `tr` dies with SIGPIPE, the pipeline returns 141. The provisioning script exited 141 having printed exactly one line of output.
