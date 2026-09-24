# Draft report → AWS, "Secure AI Agents on Amazon EKS"

**Status:** draft, not sent. **Target:** no public issue tracker — the workshop is hosted on Workshop Studio (`catalog.workshops.aws/ai-agents-on-eks`). Send via the workshop's in-page feedback control, the authoring team if reachable, or `aws-security@amazon.com` if they'd rather route it as a security report. Written channel-agnostically so it can be pasted into any of those.

**This is the substantive half of defect 001.** Unlike the agent-sandbox side, this is *not* already fixed: the workshop pins the affected controller version.

---

**Subject:** Security defect in "Secure AI Agents on Amazon EKS" — the module 900 sandbox air-gap fails open while the sandbox is running untrusted code

### One-line statement

The supplemental air-gap `NetworkPolicy` selects `agents.x-k8s.io/warm-pool-sandbox`, a label the agent-sandbox controller removes at claim time. The air gap therefore covers the sandbox for exactly as long as it is idle, and stops covering it the instant it is handed untrusted, model-written code. Because the workshop pins agent-sandbox **v0.5.0**, nothing else covers the gap.

I verified this by running it, not by reading it. A claimed sandbox opened a TCP connection to `1.1.1.1:443`.

### Why I'm reporting it rather than just fixing my copy

This is published security-teaching material. Readers are being taught the pattern "select the label warm-pool pods actually carry," and they will carry it into their own clusters. The module's own README asserts the property this breaks:

- `900-sandboxed-code-exec/README.md:11` — "runs hardware-isolated and air-gapped — no network, no credentials."
- `900-sandboxed-code-exec/README.md:29-30` — "The vpc-cni NetworkPolicy agent (base.tf) enforces the air-gap and the router-ingress lock."

### Affected artifacts

| Path | Role |
|---|---|
| `terraform/manifests/agentsandbox/sandbox-airgap-networkpolicy.yaml` | **The defect.** `podSelector` is `matchExpressions: [{key: agents.x-k8s.io/warm-pool-sandbox, operator: Exists}]`. |
| `terraform/agentsandbox.tf` (step 8 of the `local-exec` installer) | Applies it, and documents the reasoning that leads to the wrong selector. |
| `manifests/agentsandbox/manifest.yaml` | Pins `agent-sandbox-controller:v0.5.0` — the version on which this fails open. |

### The diagnosis in your own manifest header is correct; the remedy is not

Your header already says:

> agent-sandbox v0.5.0's controller generates a `<template>-network-policy` whose podSelector targets `agents.x-k8s.io/sandbox-template-ref-hash`. But warm-pool-ADOPTED sandbox pods are stamped with `agents.x-k8s.io/warm-pool-sandbox` (+ sandbox-name-hash) and do NOT carry the template-ref-hash label — so the generated policy matches ZERO pods and the intended `egress: []` air-gap is never enforced.

That is right. The problem is that the substitute label is **also** not stable across the sandbox lifecycle — it is a pool-membership marker, and the controller removes it to take the pod out of the pool.

| Label | Pooled pod | Claimed pod | Safe as a policy selector? |
|---|---|---|---|
| `agents.x-k8s.io/sandbox-template-ref-hash` | absent (on v0.5.0) | absent | No |
| `agents.x-k8s.io/warm-pool-sandbox` | **present** | **removed** | **No — this is the defect** |
| `sandbox-kind` (yours, via `podTemplate.metadata.labels`) | present | present | **Yes** |

### Evidence

Claimed pod vs still-pooled control, same template, same namespace, same image, same node pool — the only difference is the label the controller removed:

```
# CLAIMED pod — no policy selects it
$ kubectl exec -n repro-warmpool-label repro-pool-jfqg9 -- nc -zv -w 5 1.1.1.1 443
1.1.1.1 (1.1.1.1:443) open          exit=0

# CONTROL, still POOLED — the policy does select it
$ kubectl exec -n repro-warmpool-label repro-pool-45h28 -- nc -zv -w 5 1.1.1.1 443
                                     exit=1
```

Preceded by a CNI pre-check proving this cluster enforces NetworkPolicy at all, because a bare "blocked" is equally consistent with a CNI that enforces nothing.

### Version sensitivity — and the simplest fix

I bisected the controller behaviour across ten releases:

| Controller | `spec.networkPolicy` enforced on a **claimed** warm-pool pod |
|---|---|
| **v0.5.0, v0.5.1** | **no — fails open** |
| v0.5.2 – v0.5.6, v1.0.0 – v1.0.2 | yes |

From **v0.5.2** the controller stamps `sandbox-template-ref-hash` onto the pod, so the generated policy does its job and the supplemental policy is no longer load-bearing.

**Fix option 1 (recommended): bump the pinned controller to ≥ v0.5.2.** This removes the original reason the supplemental policy exists.

**Fix option 2: correct the selector.** One line, works on any version:

```yaml
spec:
  podSelector:
    matchLabels:
      sandbox-kind: python        # was: matchExpressions on agents.x-k8s.io/warm-pool-sandbox
```

You already ship `sandbox-kind` and already rely on it surviving the claim for your own `kubectl -l sandbox-kind=python` verification commands — the insight just wasn't carried to the NetworkPolicy. It also removes an unintended coupling: the bare `warm-pool-sandbox` `Exists` selector matches **all** warm-pool pods, so module 1000's coding pods are additionally hit by the python air-gap's `egress: []` while warm. Selecting `sandbox-kind` makes the two policies disjoint.

Doing both is best: bump the pin *and* fix the selector, so the lab is correct independently of the controller version a reader happens to install.

### Two process suggestions, worth more than the one-line fix

1. **Verify in the claimed state.** The module's current verification can be satisfied entirely by a pooled pod, which is why this survived. Ask the reader to hold a claim open and re-check.
2. **Pair every "blocked" assertion with an unselected control pod that must connect.** "Blocked" alone is equally consistent with a working policy, a broken pod, a dead network, and a CNI that silently enforces nothing. This is a real failure mode, not a hypothetical — kindnet no-ops NetworkPolicy entirely, so a reader rebuilding this on kind would see a green lab that enforces nothing.

### Severity

**High.** Fails open; invisible to every normal check (the manifest reads correctly, `kubectl get networkpolicy` shows the policy present with a plausible selector, and `kubectl describe` on a *pooled* pod confirms it applies). Not critical only because exploitation requires code execution inside the sandbox — which is precisely the assumed position in this module's own threat model, and the sandbox's filesystem holds customer order data.

### Reproduction

Self-contained reproducer needing only a stock agent-sandbox install and a NetworkPolicy-enforcing CNI, with full transcripts for all ten controller versions: [attach `repro-001/`]. Against your own environment: deploy through module 900, drive one `run_python` call so a claim binds, then re-check `kubectl get pod -n agent-sandbox --show-labels` and attempt outbound TCP from the bound pod.

### What I did not verify

- **Not reproduced on EKS with the AWS VPC CNI.** My measurements are k3s + Flannel + kube-router. The failure is in *label selection*, which is CNI-independent, and your manifest header states the VPC CNI's eBPF enforcement reaches kata microVMs — but I have not run the claimed-pod egress test on your actual stack. This is the one thing I'd most want you to confirm.
- Ran `runsc` (gVisor), not `kata-fc` (Firecracker). Nothing in the defect depends on the runtime class.
- Did not read agent-sandbox controller source; "dropping the label is how the pod leaves the pool" is inference from observed behaviour.
