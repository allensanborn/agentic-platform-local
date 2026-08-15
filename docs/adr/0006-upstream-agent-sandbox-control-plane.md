# ADR 0006 — install upstream agent-sandbox; do not hand-roll pod vending

**Status:** accepted
**Date:** 2026-08-15

## Decision

Install the upstream **`kubernetes-sigs/agent-sandbox` v0.5.0** control plane (controller,
CRDs, `sandbox-router`) and drive it from the broker with the official **`k8s-agent-sandbox`
Python SDK**, exactly as the workshop does. Do **not** have the broker create and delete
sandbox Pods directly through the Kubernetes API.

## The alternative that was considered

Option (b) was: skip the CRDs, give the broker a Role over `pods`, and have
`sandbox_runner.py` create a pod, poll it Ready, POST files to it, and delete it. Less
machinery, no upstream version to track, and the isolation story (gVisor + `egress: []` +
no service-account token) would be unchanged, because all of that lives on the pod spec.

## Why upstream won

**It installs cleanly here, which was the only real question.** Both images are multi-arch
and publish arm64, so nothing had to be rebuilt:

```
$ docker manifest inspect registry.k8s.io/agent-sandbox/agent-sandbox-controller:v0.5.0
  ... "platform": {"architecture": "arm64", "os": "linux"}
$ docker manifest inspect us-central1-docker.pkg.dev/k8s-staging-images/agent-sandbox/sandbox-router:latest-main
  ... "platform": {"architecture": "arm64", "os": "linux"}
```

The controller, the webhook, the router, the CRDs, the warm pool and the claim flow all came
up on k3s v1.35 / arm64 on the first attempt, with no patches. Option (b) is only worth its
loss of fidelity if (a) does not work, and (a) works.

**Warm pooling is not a nice-to-have here, it is what makes the lab demonstrable.** A cold
sandbox is a pod pull plus a `runsc` start; a claim against a warm pool is bound in under a
second. The workshop needs pooling because a Firecracker node takes minutes to provision.
This build needs it for a different reason — the interactive loop is a person typing into a
chat UI, and a ten-second stall reads as "broken" rather than "cold".

**The claim/relabel lifecycle is itself part of what lab 5 teaches**, and hand-rolled pod
creation would quietly delete it. Single-use is visible as a state transition on real
objects:

```
# during a run
NAME                     READY   SANDBOX                    REASON
sandbox-claim-cbcbf59f   False   gvisor-python-pool-5nbx5   DependenciesNotReady

NAME                       READY  LABELS
gvisor-python-pool-4k9t7   1/1    ...,agents.x-k8s.io/warm-pool-sandbox=0870f7fb,sandbox-kind=python
gvisor-python-pool-5nbx5   0/1    ...,sandbox-kind=python     <-- CLAIMED, pulled out of the pool
gvisor-python-pool-g9scb   1/1    ...,agents.x-k8s.io/warm-pool-sandbox=0870f7fb,sandbox-kind=python

# after the run: claim gone, 5nbx5 destroyed, pool refilled to 2
```

**Fidelity is the repo's whole thesis.** The point of this rebuild is to test how much of the
workshop's argument survives without AWS. Replacing the control plane with a bespoke one
would answer a different, less interesting question. `sandbox_runner.py` is copied from the
workshop with the words "microVM" and one warm-pool name changed, which is the strongest
possible evidence that the substitution is at the platform layer and not in the application.

## Consequences

### The workshop's air-gap NetworkPolicy does not work, and neither does upstream's

Both known selectors miss. This was found by running hostile code inside a *claimed* sandbox,
not by reading manifests.

- The controller's generated `<template>-network-policy` selects
  `agents.x-k8s.io/sandbox-template-ref-hash`. Warm-pool pods never carry that label, so it
  matches zero pods. The workshop documents this and ships a supplemental policy.
- The workshop's supplemental policy selects `agents.x-k8s.io/warm-pool-sandbox`. That label
  *is* present — **while the pod sits idle in the pool**. The controller removes it on claim,
  because dropping the label is how the pod is taken out of the pool. So the policy protects
  the sandbox for exactly as long as the sandbox is doing nothing, and stops protecting it
  the instant it is handed untrusted code.

Measured, before the fix, from inside a claimed sandbox:

```
--- stdout ---
EGRESS REACHED THE INTERNET
sa token dir exists: False
kernel: 4.19.0-gvisor
```

`platform/sandbox/sandbox-airgap-networkpolicy.yaml` therefore selects `sandbox-kind: python`
— set by our SandboxTemplate's `podTemplate.metadata.labels`, a non-reserved key that
propagates to the pod and survives the claim relabel. The workshop already depends on that
survival property for its own `kubectl -l sandbox-kind=python` verification commands; it just
did not carry the insight across to the policy. After the fix, same code, same claimed
sandbox:

```
--- stdout ---
egress blocked: ConnectionRefusedError
sa token dir exists: False
kernel: 4.19.0-gvisor
```

This is exactly the failure ADR 0001 was written to avoid, arriving from a direction ADR 0001
did not anticipate: not a CNI that ignores policy, but a correctly-enforced policy whose
selector matches nothing. **A policy that matches no pods and a CNI that enforces no policy
are indistinguishable from the outside.** The control is the discipline that separates them —
run the same probe from a pod the policy does *not* select and confirm it succeeds, or the
"blocked" result proves nothing about the policy.

### Version coupling

The SDK and the controller share a CRD contract, so `requirements.txt` pins
`k8s-agent-sandbox==0.5.0` against the v0.5.0 control plane installed by
`scripts/install-agent-sandbox.sh`. They move together or not at all.

### The router is unauthenticated

The v0.5.0 SDK has no field on any connection config for the router's `ROUTER_AUTH_TOKEN`, so
the router runs with `ALLOW_UNAUTHENTICATED_ROUTER=true` — upstream's own default in this
manifest. Access is enforced one layer down instead:
`platform/sandbox/router-ingress-networkpolicy.yaml` admits only pods labelled
`app: code-executor` in namespace `default`. On k3s that is enforced by kube-router. This is
the workshop's arrangement, unchanged.

### Vendored manifests

`platform/sandbox/agent-sandbox/{manifest,extensions,sandbox_router}.yaml` are the workshop's
vendored copies with `__ECR__` repointed at the upstream registries. They are ~800KB of CRD,
checked in on purpose: pinning beats `kubectl apply -f https://…` for something that vends
execution environments.
