# Deterministic infra suite

Gates the platform properties the labs are supposed to demonstrate. This is tier 1 of the
strategy in [ADR 0012](../docs/adr/0012-testing-and-eval-strategy.md): it asserts that the
**control points** behave, not that the model gives good answers. Response quality is tier 2
(beads `llm-wiki-1fi.3`/`1fi.4`).

## Run

```bash
uv venv --python 3.12 tests/.venv
. tests/.venv/bin/activate && uv pip install -r tests/requirements.txt
cd tests && python -m pytest
```

Port-forwards are started and torn down by the suite itself — you do **not** need
`make forwards` in another shell.

## What each file pins

| file | lab | property |
|---|---|---|
| `test_00_cluster.py` | cold start | every required control point is deployed and Available; gVisor RuntimeClass handler is `runsc` |
| `test_10_gateway_alias.py` | 0 | the alias table resolves, and the two aliases reach **different** backend models |
| `test_20_tool_authz.py` | 3 + 4 | anonymous MCP is 401; two personas get **different** tool lists; the gateway is the only gate |
| `test_30_sandbox_airgap.py` | 5 | a **claimed** sandbox cannot reach the internet, has no SA token, runs the gVisor kernel |
| `test_40_coding_egress.py` | 6 + 7 | the coding sandbox's two-destination allowlist holds exactly |
| `test_50_trace_nesting.py` | 2 | gateway spans **descend from** the agent's `/chat` root — one tree, not two |

## Three rules this suite is built on

**Every deny is paired with a control.** A "blocked" result is equally consistent with a
working NetworkPolicy, a broken network, and a probe that never ran. Only *blocked here while
reaching there* isolates the policy as the cause. Both egress files assert the control
explicitly, and will fail if the control pod cannot reach the internet.

**An empty result is never a passing result.** `kubectl()` raises rather than returning an
empty string, and the sandbox probe has a `test_probe_actually_executed` guard that runs
before anything reads its output. This project has repeatedly been misled by a failed
command's empty output being read as a meaningful zero.

**Exceptions get flattened before they get asserted on.** The MCP client runs inside an anyio
TaskGroup, so an HTTP 401 arrives as `ExceptionGroup: unhandled errors in a TaskGroup (1
sub-exception)` — `str()` of which contains no status code at all. Use `conftest.explain()`.

## If the whole run aborts with CAPACITY HOLD

That is the pre-flight gate, not a product failure. The k3s API on this box can starve under
burst load; controllers then lose their leader-election lease, exit, restart, and re-LIST,
which feeds the loop. Wait for it to settle and re-run. Full mechanism in beads
`llm-wiki-661.23`.
