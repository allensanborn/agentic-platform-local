# ADR 0013 — Where the tests run: a launchd job on this Mac, plus a deliberately tiny GitHub Actions job

**Status:** accepted
**Date:** 2026-08-17
**Related:** [ADR 0012](0012-testing-and-eval-strategy.md) (what the tests are), [ADR 0001](0001-k3s-not-kind.md) (why the cluster is k3s), beads `llm-wiki-1fi.5` (this decision), `llm-wiki-661.23` (the capacity collapse that shapes it)

## Decision, in one paragraph

Run the **infra suite** (`tests/`, 42 tests, ~6.5 min) from a **macOS LaunchAgent on this box**, once a day, against the live cluster — because that suite's subject *is* the live cluster and it cannot be moved. Run a **hermetic subset** (the two unit-test suites, plus manifest and script syntax) on a **stock GitHub Actions runner** on push and weekly, and be loud in the workflow itself about the fact that it covers roughly a fifth of the tests and none of the properties the repo actually claims. Do **not** stand up a self-hosted runner. The scheduled run's output is a status file and a macOS notification, not a green tick nobody looks at, because the requirement in `llm-wiki-1fi.5` is that a regression becomes *visible without someone remembering to look*.

## The constraint that decides it

The tier-1 suite is not hermetic and was never intended to be. From `tests/README.md` and the suite itself, a run needs:

- a **running k3d cluster** with the full ~30-pod stack — gateway, agentgateway, Keycloak, Langfuse, the agent-sandbox control plane, gVisor's `runsc` on the node;
- **Ollama on the host** with `qwen3:8b` and `llama3.2:1b` pulled (~6.5 GB), reachable at `localhost:11434`, because the gateway's alias table resolves to it;
- **kube-router's NetworkPolicy enforcement**, which is the whole point of ADR 0001 and is a property of the *node*, not of the manifests;
- ~6.5 minutes of wall clock, of which a good share is a model actually answering.

Every one of those is a property of *this machine in this state*. The suite deliberately asserts on the deployed thing rather than a simulation of it, which is what makes it worth anything — and is exactly what makes it unportable.

The second constraint is `llm-wiki-661.23`. k3s here runs on kine-over-SQLite; under burst load the datastore slows, controllers lose their leader-election lease, controller-runtime treats that as fatal and exits, and the restart's re-LIST feeds the loop. The suite already refuses to run in that window (`conftest.capacity_gate`, which checks nodes Ready, no `CrashLoopBackOff`, **and** Gateway `Programmed=True`). Any scheduler wrapping this suite inherits a third outcome beyond pass and fail: **hold**, meaning nothing was measured. A scheduler that cannot distinguish those three is worse than no scheduler, because "no red" starts meaning "no data".

## Options

### (a) GitHub Actions on a hosted runner — impossible for the full suite, worth it for a slice

A hosted `ubuntu-latest` runner *can* create a k3d cluster; that is not the blocker. Four things are:

1. **No model.** `qwen3:8b` is ~5 GB and needs to run inference. A hosted runner has 4 vCPU / 16 GB and no GPU. `test_10` asserts two aliases reach *different* backend models, and `test_50` needs a real `/chat` turn to produce a trace. Pulling and running two models on every CI run is minutes of download and minutes of CPU inference, on hardware slower than the laptop that already struggles.
2. **No time budget.** The suite is 6.5 min *on a warm cluster*. Cold-starting the stack from `make up-all` first — CRDs, three Helm releases, image builds, Langfuse's expensive startup — puts a run well past the point where anyone would leave it enabled. The 6-hour job cap is not the binding limit; patience is.
3. **gVisor.** `test_00` asserts the `RuntimeClass` handler is `runsc` and `test_30` asserts a claimed sandbox runs the gVisor kernel. `runsc` inside a nested-virtualised hosted runner is a project of its own, and if it were faked the test would assert nothing.
4. **The capacity bug is about this box.** Even if all of the above were solved, a green cloud run would say nothing about whether *this* cluster is healthy, which is the failure mode that has actually bitten — twice, both times mis-attributed (`llm-wiki-661.23`).

A **subset**, however, is genuinely hermetic and genuinely cheap: the broker unit tests (`make sandbox-unit`), the dispatcher unit tests (`make coding-unit`), YAML parse-validity across `platform/` and `modules/`, `bash -n` over `scripts/`, and a `pytest --collect-only` of `tests/` (which imports `conftest.py` and every test module, so it catches an import error or a syntax error in the suite without touching a cluster). That runs in under a minute on a free runner and catches the class of breakage where someone edits a test file and does not run it.

It must be labelled honestly. This workflow does **not** test the gateway, the alias table, tool authorization, the air-gap, the egress allowlist, or trace parentage — that is, none of the seven labs. A green tick on it means "the Python still imports", nothing more. Half the value of adding it is having somewhere to write that sentence down.

### (b) A self-hosted GitHub Actions runner on the Mac

This is the option that looks most like real CI and buys the least here.

It adds a long-lived daemon holding a registration token for a GitHub repo, whose job is to execute arbitrary workflow YAML from that repo against the machine that has `kubectl` admin on the cluster and the Ollama models. For a solo learning repo, that is a real attack surface added for a scheduling feature `launchd` already provides.

It also gets the trigger wrong. Self-hosted runners exist to run on **push**. But a push is exactly the moment the developer is at the keyboard editing the cluster, and a 6.5-minute suite firing then is both redundant (they can type `make test`) and actively harmful: it lands burst load on the datastore that `llm-wiki-661.23` says is the thing that collapses. The signal worth automating here is *time*-based — "is the cluster still good this morning" — not *change*-based.

Rejected: strictly more moving parts and more exposure than (c), for a trigger model that fits the failure mode worse.

### (c) A local scheduled job (launchd) — chosen

The parent repo (`llm-wiki`) already runs a weekly LaunchAgent and has paid for the non-obvious parts. Its `CLAUDE.md` "Mirrored corpora" section records three, all found the hard way on 2026-08-16, and two of them apply directly:

- **The runner must live outside `~/Documents`.** macOS TCC denies launchd-spawned processes access to that tree, so executing a script from the checkout dies with `Operation not permitted` (exit 126) *before writing a single log line*. The plist itself loads fine — launchd is privileged; the spawned `bash` is not. The fix there was to have the installer **copy** the runner and a path-substituted plist into `~/Library/`. This repo lives at `~/Documents/code/github/allensanborn/agentic-platform-local`, so it has the identical problem, and takes the identical fix.
- **The job runs against its own clone**, hard-reset to `origin/main`, not the everyday checkout — and refuses to run on a dirty tree. In `llm-wiki` that mattered because the job commits. Here it matters for a different reason worth stating separately: the everyday checkout nearly always has WIP in it, and a suite that imports test modules from a tree someone is mid-edit in produces failures attributable to nothing. A pinned clone means every result carries a commit SHA that explains it.
- The third trap (nested `claude -p` survives under launchd) does not apply — nothing here calls a model runner from the job.

One trap this job has that `llm-wiki`'s does not: **it depends on external state it does not own** — a cluster and an Ollama daemon. So the runner has to treat "could not measure" as a first-class outcome and say so, rather than exiting non-zero and training the reader to ignore it.

`StartCalendarInterval` also gives the awake-Mac caveat for free with the right behaviour: if the machine is asleep at the fire time, launchd runs the job once on next wake, which for a daily health check is exactly right.

### (d) On-demand `make test` only, no automation

The status quo, and it is not sufficient on its own terms. `llm-wiki-1fi.5` states the requirement: *"whatever is chosen must make a regression VISIBLE without someone remembering to look — the whole point is catching what a human would not."* On-demand-only means the suite runs when someone suspects a problem, which selects precisely against the silent regressions it was built for. The suite's own history is the argument: the capacity gate was widened only after a run produced six bogus product failures for one unprogrammed gateway, and that was found by running it, not by suspecting it.

`make test` remains the primary human entry point. It is just not the whole answer.

## What is being built

- `scripts/run-tests-scheduled.sh` — the runner. Idempotently maintains its own clone outside `~/Documents`, hard-resets it to `origin/main`, refuses to proceed if that clone is dirty, pre-flights Docker / the k3d cluster / the Kubernetes API / Ollama and its two models, applies the gateway recovery below if needed, runs `make test`, writes a timestamped log plus a one-line `status` file, and posts a macOS notification on anything that is not a pass.
- `scripts/agentic-platform-tests.plist.template` — `StartCalendarInterval` daily at 09:20 local, with an explicit `PATH` (launchd gives a process almost nothing, and `kubectl`, `uv`, `docker` and `ollama` all live in Homebrew or `~/.local/bin`).
- `scripts/install-scheduled-tests.sh` — copies runner + path-substituted plist into `~/Library/`, loads the agent. `--uninstall` removes it. **Re-run after editing either file** — a `git pull` does not update the installed copies, which is the same footgun the parent repo documents.
- `.github/workflows/hermetic.yml` — the subset from option (a), on push, PR, and a weekly cron, with the coverage disclaimer in the workflow body and in the job summary.

No Makefile targets. The Makefile is the interface for things a human does interactively; installing a background daemon is a deliberate, rare, opt-in act, and making it `make install-tests` invites it being run by muscle memory. `scripts/install-scheduled-tests.sh` has to be typed on purpose.

## The gateway recovery, and why it is in the runner rather than the suite

After a capacity collapse the AI gateway does **not** self-heal. Controllers return `Running`, both nodes go back to `Ready`, and the Gateway sits `Programmed=False` with no data-plane config — the exact state that produced six false product failures and forced the capacity gate to be widened. Clearing it takes `kubectl rollout restart` of `ai-gateway-controller` (`envoy-ai-gateway-system`) and `envoy-gateway` (`envoy-gateway-system`).

That recovery belongs in the scheduler, not in `conftest.py`, and the boundary is worth stating: **the suite must never repair what it measures.** A test fixture that restarts a controller to make an assertion pass has destroyed the assertion. The runner is a separate actor that brings the environment to a defined state *before* handing over, and it records loudly in the log that it intervened — so a "pass" that required a restart is never mistaken for a cluster that was healthy on its own.

The runner attempts the restart at most once per invocation, then re-checks. If the Gateway is still not `Programmed` it records `HOLD` and does not run the suite, rather than escalating to anything more destructive. Nothing in the automated path ever runs `make up-all`, deletes a pod for luck, or recreates the cluster: unattended repair on a box whose failure mode is *load* is how a transient hold becomes an outage.

## Outcomes the runner distinguishes

Four, and collapsing any two of them is the mistake this is designed against:

| status | meaning | exit | notified |
|---|---|---|---|
| `PASS` | the suite ran and everything passed | 0 | no |
| `FAIL` | the suite ran and something failed — a real signal | 1 | yes |
| `HOLD` | pre-flight or the capacity gate refused; **nothing was measured** | 2 | yes |
| `SKIP` | the environment is legitimately absent (cluster down, Ollama not running) — the laptop is a laptop | 0 | no |

`SKIP` exists because this cluster is not expected to be up at all times; treating "the demo isn't running today" as a failure is how a daily check gets muted within a week. `HOLD` is separate from `SKIP` because a hold means the stack *is* up and is *degraded* — the interesting case, and the one `llm-wiki-661.23` is about.

The last run's status is a single line at `~/Library/Logs/agentic-platform-tests/status`, and `latest.log` is a symlink to the full output. Two files, greppable, no dashboard.

## Consequences

**A daily run is one more burst on the datastore.** The thing being scheduled is the thing that has been shown to trigger the collapse. Mitigations: once a day rather than hourly, at a fixed hour, never on push, and the pre-flight refuses to start on an already-degraded cluster. If daily runs turn out to *cause* holds, the honest response is to reduce the frequency, not to loosen the gate.

**A green GitHub tick will overstate coverage to anyone who has not read this ADR.** Mitigated as far as a badge can be — the workflow is named for what it is, prints its own disclaimer into the job summary, and never runs anything cluster-dependent so it cannot accidentally start looking authoritative.

**The scheduled run is invisible on any other machine.** That is inherent to option (c) and is the price of testing a laptop cluster. There is no cloud record of yesterday's result; there is a log file on the box that owns the thing being tested. Given that the subject is that box, this is the right place for it.

**Tier 2 (promptfoo, ADR 0012, beads `llm-wiki-1fi.3`/`1fi.4`) is not scheduled here.** It does not exist yet, and when it does it is model-driven and therefore slower and flakier than tier 1. It should get its own cadence — likely weekly, not daily — rather than being bolted onto this job because the job already exists. The runner takes the suite to run as an argument so that is a config change, not a rewrite.
