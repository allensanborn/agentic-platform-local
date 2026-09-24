# Defect 001 — the sandbox air-gap NetworkPolicy stops selecting the sandbox at claim time

**Severity: high (security control fails open).**
**Status: reproduced live, fix applied locally, not yet reported upstream.**
**Found:** 2026-08-16, while porting the workshop to a local k3s stack.
**Tracking:** beads `llm-wiki-661.13`.

## One-line statement

The supplemental air-gap `NetworkPolicy` selects `agents.x-k8s.io/warm-pool-sandbox`, a label the agent-sandbox controller **removes at claim time** — so the air gap covers the sandbox for exactly as long as the sandbox is idle, and stops covering it the instant it is handed untrusted, model-written code.

The policy looks correct in the manifest, and it looks correct in `kubectl get networkpolicy`. Only running hostile code inside a *claimed* sandbox exposes it.

## Affected artifacts

Workshop ("Secure AI Agents on Amazon EKS"), platform Terraform tree:

| Path | Role |
|---|---|
| `terraform/manifests/agentsandbox/sandbox-airgap-networkpolicy.yaml` | **The defect.** `podSelector` is `matchExpressions: [{key: agents.x-k8s.io/warm-pool-sandbox, operator: Exists}]`. |
| `terraform/agentsandbox.tf` (step 8 of the `local-exec` installer) | Applies that policy and documents the rationale that leads to the wrong selector. |
| `terraform/manifests/agentsandbox/sandboxtemplate-kata-fc.yaml` | The `SandboxTemplate` whose `networkPolicy.egress: []` the supplemental policy is meant to make real. |

Workshop module prose that asserts the property this defect breaks:

- `900-sandboxed-code-exec/README.md:11` — "runs hardware-isolated and air-gapped — no network, no credentials."
- `900-sandboxed-code-exec/README.md:29-30` — "The vpc-cni NetworkPolicy agent (base.tf) enforces the air-gap and the router-ingress lock."

Upstream component: `kubernetes-sigs/agent-sandbox` **v0.5.0** (controller image `registry.k8s.io/agent-sandbox/agent-sandbox-controller:v0.5.0`, as vendored by the workshop's `manifests/agentsandbox/manifest.yaml` and by this repo's `platform/sandbox/agent-sandbox/manifest.yaml`).

## Background — why the supplemental policy exists at all

agent-sandbox v0.5.0 generates a `<template>-network-policy` from the `SandboxTemplate`'s `spec.networkPolicy`. That generated policy selects `agents.x-k8s.io/sandbox-template-ref-hash`. Warm-pool-provisioned pods do not carry that label, so the generated policy matches zero pods and the template's `egress: []` is never enforced.

The workshop found that, and it says so in its own manifest header:

> WHY THIS EXISTS: agent-sandbox v0.5.0's controller generates a `<template>-network-policy` whose podSelector targets the label `agents.x-k8s.io/sandbox-template-ref-hash`. But warm-pool-ADOPTED sandbox pods are actually stamped with `agents.x-k8s.io/warm-pool-sandbox` (+ sandbox-name-hash) and do NOT carry the template-ref-hash label — so the generated policy matches ZERO pods and the intended `egress: []` air-gap is never enforced.
> — `terraform/manifests/agentsandbox/sandbox-airgap-networkpolicy.yaml`

The diagnosis is right. The remedy is not: it substitutes a second label that is also not stable across the sandbox lifecycle.

## The three candidate labels

Measured on a live cluster running the same agent-sandbox v0.5.0 control plane:

| Label | On a pooled (idle) pod | On a claimed (running) pod | Usable as a policy selector? |
|---|---|---|---|
| `agents.x-k8s.io/sandbox-template-ref-hash` | absent | absent | No — what the controller's own generated policy selects |
| `agents.x-k8s.io/warm-pool-sandbox` | **present** | **removed** | **No — this is the defect** |
| `sandbox-kind` (set by `podTemplate.metadata.labels`) | present | present | Yes |

`agents.x-k8s.io/warm-pool-sandbox` is removed on claim because *dropping that label is how the pod is taken out of the pool*. It is a pool-membership marker, not an identity marker. Selecting on it means "policy applies while pooled."

## Expected vs actual

**Expected:** a sandbox vended by the workshop's platform has no egress at any point in its life, per the module README's "air-gapped — no network" claim.

**Actual:** the sandbox has no egress while it sits idle in the warm pool. From the moment a `SandboxClaim` binds it — the moment it begins executing untrusted model-generated code — no `NetworkPolicy` in the namespace selects it, and its egress is unrestricted.

## Evidence

### 1. The label disappears on claim (live `kubectl`, recorded in beads `llm-wiki-661.13` and this repo's ADR 0006)

```
$ kubectl get pod -n agent-sandbox --show-labels
gvisor-python-pool-djw5g  ...,agents.x-k8s.io/warm-pool-sandbox=0870f7fb,sandbox-kind=python
gvisor-python-pool-jw7nj  ...,sandbox-kind=python          <-- CLAIMED: no warm-pool label
```

The same transition captured across a claim lifecycle (ADR 0006, `docs/adr/0006-upstream-agent-sandbox-control-plane.md`):

```
# during a run
NAME                     READY   SANDBOX                    REASON
sandbox-claim-cbcbf59f   False   gvisor-python-pool-5nbx5   DependenciesNotReady

NAME                       READY  LABELS
gvisor-python-pool-4k9t7   1/1    ...,agents.x-k8s.io/warm-pool-sandbox=0870f7fb,sandbox-kind=python
gvisor-python-pool-5nbx5   0/1    ...,sandbox-kind=python     <-- CLAIMED, pulled out of the pool
gvisor-python-pool-g9scb   1/1    ...,agents.x-k8s.io/warm-pool-sandbox=0870f7fb,sandbox-kind=python
```

Steady state on the same cluster today, with all pods pooled and therefore all carrying the label (captured read-only for this report, 2026-08-17):

```
$ kubectl get pod -n agent-sandbox --show-labels
NAME                       READY   STATUS    LABELS
gvisor-coding-pool-xjd8p   1/1     Running   agents.x-k8s.io/sandbox-name-hash=1fc0bf4c,agents.x-k8s.io/warm-pool-sandbox=bd733d27,sandbox-kind=coding
gvisor-python-pool-gpgxl   1/1     Running   agents.x-k8s.io/sandbox-name-hash=3bec7f4a,agents.x-k8s.io/warm-pool-sandbox=0870f7fb,sandbox-kind=python
gvisor-python-pool-gpnlz   1/1     Running   agents.x-k8s.io/sandbox-name-hash=557f3abf,agents.x-k8s.io/warm-pool-sandbox=0870f7fb,sandbox-kind=python
```

Note the pooled pods carry `warm-pool-sandbox` **and** `sandbox-name-hash`, and never `sandbox-template-ref-hash`.

### 2. The controller-generated policy selects a label no pod has

```
$ kubectl get networkpolicy -n agent-sandbox
NAME                           POD-SELECTOR                                         AGE
gvisor-coding-egress           sandbox-kind=coding                                  16h
gvisor-coding-network-policy   agents.x-k8s.io/sandbox-template-ref-hash=5ece98d6   16h
gvisor-python-airgap           sandbox-kind=python                                  16h
gvisor-python-network-policy   agents.x-k8s.io/sandbox-template-ref-hash=13724b52   16h
```

`gvisor-*-network-policy` are the controller-generated ones. Cross-referencing with the pod labels above: zero pods carry `sandbox-template-ref-hash`, so those two policies select nothing. (`gvisor-python-airgap` / `gvisor-coding-egress` are this repo's fixed policies, selecting `sandbox-kind` — see *Suggested fix*.)

### 3. The observable consequence

The defect was found empirically, not by reading manifests. Running the isolation probe's hostile-code path inside a **claimed** sandbox printed:

```
EGRESS REACHED THE INTERNET
```

and the sandbox opened a TCP connection to `1.1.1.1:443`. That string is now the regression-guard assertion in `tests/test_30_sandbox_airgap.py::test_claimed_sandbox_cannot_reach_the_internet`.

### 4. The control — why a "blocked" result alone is not evidence

Every negative egress assertion in this repo is paired with a **control pod** the policy deliberately does not select, which must *reach* the internet:

```
$ kubectl exec -n agent-sandbox airgap-control -- python3 -c \
    "import socket; s=socket.socket(); s.settimeout(5); s.connect(('1.1.1.1',443)); print('CONTROL-REACHED')"
CONTROL-REACHED
```

Without that control, "blocked" is indistinguishable from a CNI that enforces no NetworkPolicy at all — a real failure mode (kindnet silently no-ops NetworkPolicy; see `docs/adr/0001-k3s-not-kind.md`). We recommend the workshop adopt the same control in its verification steps, independently of this defect.

## Reproduction

A self-contained reproducer that needs only a stock agent-sandbox install and a NetworkPolicy-enforcing CNI is in [`repro-001/`](repro-001/README.md). It demonstrates the label disappearing on claim, which is the root cause, without needing the workshop's broker, model access, or AWS.

Against the workshop's own environment the sequence is:

1. Deploy the workshop platform through module 900 (`kata-fc-python` `SandboxTemplate` + `SandboxWarmPool` + `sandbox-airgap-networkpolicy.yaml`).
2. `kubectl get pod -n agent-sandbox --show-labels` — pooled pods carry `agents.x-k8s.io/warm-pool-sandbox`.
3. Drive one `run_python` call through the code-executor MCP broker so a `SandboxClaim` binds a pod.
4. While the claim is live, re-run step 2. The bound pod no longer carries `agents.x-k8s.io/warm-pool-sandbox`.
5. From inside that claimed sandbox, attempt an outbound TCP connect to a public address (e.g. `1.1.1.1:443`). It succeeds.
6. Confirm attribution with a control pod in the same namespace that the policy also does not select; it must also succeed, proving the CNI is enforcing and the difference is the selector.

## Impact

- **Fail-open security control.** The only window in which the air gap matters is the window in which it is not applied.
- **Invisible in every normal check.** The manifest reads correctly, `kubectl get networkpolicy` shows the policy present with a plausible selector, and `kubectl describe` on a *pooled* pod would confirm it applies. Nothing short of testing a claimed pod reveals it.
- **This is published security-teaching material.** Readers are being taught a pattern ("select the label warm-pool pods actually carry") that is unsafe, and they will carry it into their own clusters.
- **Data-exfiltration path in the taught architecture.** The sandbox exists to run untrusted model-written code with a filesystem containing customer order data. Unrestricted egress from that pod is the exact threat the module is written to close.

**Severity: high.** Not "critical" only because exploitation requires the attacker to already have code execution inside the sandbox — which is precisely the assumed position in this module's own threat model.

## Suggested fix

Select a **non-reserved label set by the template's `podTemplate.metadata.labels`**, which propagates to the pod and survives the claim relabel. The workshop already ships such a label (`sandbox-kind: python` / `sandbox-kind: coding`) and already relies on its survival for its own `kubectl -l sandbox-kind=python` verification commands — the insight simply was not carried across to the NetworkPolicy.

```yaml
# terraform/manifests/agentsandbox/sandbox-airgap-networkpolicy.yaml
spec:
  podSelector:
    matchLabels:
      sandbox-kind: python        # was: matchExpressions on agents.x-k8s.io/warm-pool-sandbox
```

Note the fix also removes an unintended coupling the current selector creates: the bare `warm-pool-sandbox` Exists selector matches **all** warm-pool pods, including the module-1000 coding pods, so while warm those pods are additionally hit by the python air-gap's `egress: []`. The workshop's own `sandbox-coding-egress-networkpolicy.yaml` header documents that union as a thing to reason about. Selecting `sandbox-kind` makes the two policies disjoint and the reasoning unnecessary.

The applied version of this fix, with the full rationale in the header, is `platform/sandbox/sandbox-airgap-networkpolicy.yaml` in this repo.

### Two suggestions beyond the one-line fix

1. **Add a claimed-state verification step to the module.** The module's current verification can be satisfied by a pooled pod. Ask the reader to hold a claim open and re-check.
2. **Pair every "blocked" assertion with an unselected control pod that must connect.** See Evidence §4.

### Separate upstream issue for `kubernetes-sigs/agent-sandbox`

Two things in v0.5.0 are worth an upstream issue in their own right, independent of the workshop:

- The controller-generated `<template>-network-policy` selects `agents.x-k8s.io/sandbox-template-ref-hash`, which warm-pool-provisioned pods do not carry, so a template's `spec.networkPolicy` is silently unenforced for exactly the pods a warm pool produces.
- `agents.x-k8s.io/warm-pool-sandbox` being removed on claim makes it unsafe as a policy selector, and nothing in the API surface signals that. A stable per-sandbox label that survives the claim relabel — or documentation stating plainly that `warm-pool-sandbox` must never be used in a NetworkPolicy — would prevent the next person making the same substitution.

## What we did not verify

- We did not reproduce this on **EKS with the AWS VPC CNI**. Our measurements are on k3s with Flannel + the kube-router network-policy controller. The failure is in *label selection*, which is CNI-independent, and the workshop's own manifest header states the VPC CNI's eBPF enforcement does reach kata microVMs — but we have not run the claimed-pod egress test on the workshop's actual stack.
- We ran `runsc` (gVisor), not `kata-fc` (Firecracker); see `docs/adr/0005-gvisor-not-kata-firecracker.md`. Nothing in this defect depends on the runtime class.
- We have not read agent-sandbox controller source to confirm *why* the label is dropped; "dropping the label is how the pod leaves the pool" is our inference from the observed behaviour, not a quote from upstream code.
- ~~We have not confirmed whether agent-sandbox versions after v0.5.0 change either label's
  lifecycle.~~ **Resolved 2026-09-24 by a version sweep** (`repro-001/evidence/transcripts/`).
  The generated-policy bug is **fixed in v0.5.2**: on v0.5.0 and v0.5.1 a claimed pod reached
  `1.1.1.1:443`; from v0.5.2 through v1.0.2 it is blocked. The `warm-pool-sandbox` label is
  still removed at claim time on v1.0.2, so the selector guidance in this report stands, but
  the controller-side issue below is **no longer a defect on current releases** — it is a
  documentation gap, rewritten as [`reports/001a`](reports/001a-agent-sandbox-docs-issue.md).
  The workshop-side defect is unaffected, because the workshop pins v0.5.0.
