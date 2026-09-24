# Upstream defect reports

Defects found in third-party material while building this repo — a local, AWS-free port of
the AWS **"Secure AI Agents on Amazon EKS"** workshop. Each report is self-contained: an
upstream maintainer should be able to act on one without reading the rest of this repo.

Everything here was found by *running* the thing, not by reading it. That is the pattern
worth noting: both defects look correct in their manifests, and defect 001 also looks correct
in `kubectl` output.

## Index

| # | Title | Component | Severity | Failure mode |
|---|---|---|---|---|
| [001](001-airgap-networkpolicy-claimed-sandbox.md) | Air-gap NetworkPolicy stops selecting the sandbox at claim time | AWS workshop (module 900/1000 platform Terraform) + `kubernetes-sigs/agent-sandbox` v0.5.0 | **High** | **fails open** |
| [002](002-a2a-authn-wrong-crd-path.md) | `a2a-authn.yaml` targets `spec.authorization`, which does not exist | AWS workshop (module 800) | Medium | fails closed |

`repro-001/` holds a minimal, dependency-free reproducer for defect 001, plus transcripts of it
run against every agent-sandbox release from v0.5.0 to v1.0.2.

> **Scope note (2026-09-24).** Defect 001 has two halves. The `kubernetes-sigs/agent-sandbox`
> half was **fixed upstream in v0.5.2** and is no longer a bug; what remains there is a
> documentation gap. The AWS workshop half is **still live**, because the workshop pins
> v0.5.0. See [Reporting status](#reporting-status).

## The two are not the same kind of problem

They were briefly framed together as "two fail-open security controls." **That framing was
wrong** and is retracted; only 001 is a security defect.

**001 fails open.** The air-gap `NetworkPolicy` selects `agents.x-k8s.io/warm-pool-sandbox`, a
label the agent-sandbox controller removes when a sandbox is claimed. The protection covers
the sandbox for exactly as long as the sandbox is idle, and lapses the instant it starts
running untrusted model-written code. The manifest reads correctly and
`kubectl get networkpolicy` shows the policy present with a plausible selector. It was found
only by running hostile code inside a *claimed* sandbox and watching it print
`EGRESS REACHED THE INTERNET`.

**002 fails closed.** `spec.authorization` does not exist in `AgentgatewayPolicy` v1alpha1
(agentgateway-crds 1.4.1); the field lives at `spec.traffic.authorization`. We first assumed
the unknown field would be silently pruned, leaving a green-looking policy that gated nothing.
Measurement says otherwise: it is rejected loudly under strict decoding, and under lenient
decoding a CEL required-oneof rule rejects the resulting empty spec. Nobody is misled about
enforcement. It is a correctness/bit-rot bug that makes lab 800 unfollowable as written — not
a vulnerability.

The correction is worth keeping visible. The plausible-sounding schema inference was wrong,
and only a two-command `--dry-run=server` check caught it.

## Method notes that apply to both

- **Severity is calibrated to measured behaviour, not to how alarming the manifest looks.**
- **Negative results need a control.** "Egress blocked" is worthless on its own — it is
  equally consistent with a broken pod, a dead network, or a CNI that enforces nothing
  (kindnet silently no-ops NetworkPolicy; see `docs/adr/0001-k3s-not-kind.md`). Every egress
  assertion in this repo is paired with an unselected control pod that must *reach* the
  internet. Defect 001's report and reproducer both carry that pairing.
- **Versions are pinned in each report**, because both defects are version-sensitive:
  agent-sandbox v0.5.0 for 001, agentgateway-crds 1.4.1 for 002.

## Local fixes

Neither defect is worked around silently. Each fix lives in the manifest it corrects, with a
header explaining the divergence from upstream:

- 001 → `platform/sandbox/sandbox-airgap-networkpolicy.yaml` (selector changed to
  `sandbox-kind`, a non-reserved template-supplied label that survives the claim relabel),
  guarded by `tests/test_30_sandbox_airgap.py` and `make sandbox-airgap`.
- 002 → `modules/800-a2a-authz/policies/a2a-authn.yaml` (rule moved to
  `spec.traffic.authorization`).

## Reporting status

**Updated 2026-09-24 after a version sweep.** Both reports are drafted in [`reports/`](reports/).
**Neither will be sent for now** — 001 is being carried as a defect local to *this* repo pending
further validation against a fixed controller release. The drafts are kept because the analysis in
them is the record of what was measured, not because a report is queued.

| Report | Target | State |
|---|---|---|
| [`001a`](reports/001a-agent-sandbox-docs-issue.md) | `kubernetes-sigs/agent-sandbox` | **Re-scoped — no longer a bug report.** Draft, not filed. |
| [`001b`](reports/001b-aws-workshop-report.md) | AWS workshop (Workshop Studio) | **Still a live security defect.** Draft, not sent. |
| 002 | AWS workshop (module 800) | Not yet drafted. |

### What the version sweep changed

`repro-001/run-repro.sh` was run against every agent-sandbox release from v0.5.0 to v1.0.2;
the transcripts are in [`repro-001/evidence/transcripts/`](repro-001/evidence/transcripts/).

| Controller version | `spec.networkPolicy` enforced on a warm-pool pod? | Claimed pod reaches the internet? |
|---|---|---|
| v0.5.0, v0.5.1 | no | **yes — reached `1.1.1.1:443`** |
| v0.5.2 – v0.5.6, v1.0.0 – v1.0.2 | yes | no — blocked |

So **the controller-side half of defect 001 was fixed upstream in v0.5.2.** The report to
`kubernetes-sigs/agent-sandbox` is therefore *not* a bug report. What survives there is a
documentation gap: `agents.x-k8s.io/warm-pool-sandbox` is still removed at claim time
(confirmed current on v1.0.2), and nothing in the API or docs warns that this makes it unsafe
as a `NetworkPolicy` `podSelector`. Filed as `kind/documentation`, plus a question about
whether the v0.5.2 fix was flagged as security-relevant for anyone still pinned below it.

**The AWS workshop half is not fixed, precisely because the workshop pins v0.5.0** — the
upstream fix never reaches it. That report stands as written.

Tracked as beads `llm-wiki-661.13` (001) and `llm-wiki-661.18` (002).
