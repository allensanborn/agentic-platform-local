# Draft issue → `kubernetes-sigs/agent-sandbox`

**Status:** draft, not filed. **Target:** https://github.com/kubernetes-sigs/agent-sandbox/issues
**Scope note:** this is **not** a bug report. The controller-side bug this started from is **already fixed** (v0.5.2). What remains is a documentation / API-guidance gap plus one question about release-note handling. File it as `kind/documentation`.

---

**Title:** Document that `agents.x-k8s.io/warm-pool-sandbox` must not be used as a NetworkPolicy selector

### Summary

`agents.x-k8s.io/warm-pool-sandbox` is removed from a warm-pool sandbox's pod at claim time. That is correct behaviour — dropping the label is how the pod leaves the pool — but it makes the label unsafe as a `NetworkPolicy` `podSelector`, because any policy selecting it stops applying at exactly the moment the sandbox begins doing work.

Nothing in the API surface or docs signals this. Someone reaching for "the label warm-pool pods actually carry" will pick this one, and the resulting policy will look correct in the manifest **and** in `kubectl get networkpolicy`.

I hit this via a third-party workshop that made exactly that substitution. I'm not filing about the workshop here — just asking that the label's lifecycle be documented so the next person doesn't repeat it.

### Confirmed still current on v1.0.2

```
# pooled
repro-pool-m5zh6  ...,agents.x-k8s.io/warm-pool-sandbox=a2106d30,repro-kind=sandbox

# same pod, after a SandboxClaim binds it
{"agents.x-k8s.io/claim-uid":"4a4bfaa1-...","agents.x-k8s.io/sandbox-name-hash":"10316c17",
 "agents.x-k8s.io/sandbox-template-ref-hash":"0d20a304","repro-kind":"sandbox"}
```

`warm-pool-sandbox` is gone; `sandbox-template-ref-hash` and any `podTemplate.metadata.labels` survive.

### Suggested wording

In the warm-pool docs and/or the label reference:

> `agents.x-k8s.io/warm-pool-sandbox` is a **pool-membership marker**, not a sandbox identity marker. The controller removes it when a `SandboxClaim` binds the sandbox. Do not use it in a `NetworkPolicy` `podSelector` or any other selector that must apply to a *running* sandbox — such a policy silently stops applying at claim time. To select sandboxes regardless of lifecycle state, use a label you set yourself via `spec.podTemplate.metadata.labels`.

### Secondary question — was the v0.5.2 fix flagged as security-relevant?

Separately, I bisected the related controller behaviour across releases, on a clean k3d cluster (k3s v1.35.5, Flannel + kube-router), with a CNI pre-check and a paired control pod on every egress assertion:

| Controller | Pods carry `sandbox-template-ref-hash` | `spec.networkPolicy: {egress: []}` actually enforced on a **claimed** warm-pool pod |
|---|---|---|
| v0.5.0, v0.5.1 | no | **no — pod reached `1.1.1.1:443`** |
| v0.5.2 – v0.5.6, v1.0.0 – v1.0.2 | yes | yes — blocked |

So on **v0.5.0 and v0.5.1**, a `SandboxTemplate`'s `spec.networkPolicy` was silently unenforced for warm-pool-provisioned pods: the generated `<template>-network-policy` selected `sandbox-template-ref-hash`, which at that point existed only on the `Sandbox` CR and not on the pod, so it matched zero pods.

That's fixed, and I'm glad it is. The question is only whether it was recognised as security-relevant at the time — anyone still pinned to v0.5.0/v0.5.1 who is relying on `spec.networkPolicy` for isolation is unprotected and has no signal. A release-note or advisory callout would help them. If this was already tracked somewhere, point me at it and I'll close this section.

### Reproducer

Self-contained, needs only a stock agent-sandbox install and a NetworkPolicy-enforcing CNI: [link to `repro-001/`]. Executed 2026-09-14 against all ten releases above; transcripts included.

### Environment

k3d v5.9.0 / k3s v1.35.5-k3s1 (Flannel + kube-router), OrbStack 29.4.0, darwin/arm64. Controller images `registry.k8s.io/agent-sandbox/agent-sandbox-controller:<version>`.

### What I did not verify

- Not tested on EKS with the AWS VPC CNI. The label-lifecycle behaviour is CNI-independent; the egress observations are not.
- I did not read controller source. "Dropping the label is how the pod leaves the pool" is inference from observed behaviour.
