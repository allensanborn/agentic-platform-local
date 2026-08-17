# Minimal reproducer — `agents.x-k8s.io/warm-pool-sandbox` is removed at claim time

Companion to [defect 001](../001-airgap-networkpolicy-claimed-sandbox.md).

This reproducer isolates the **root cause**: a warm-pool sandbox pod loses the
`agents.x-k8s.io/warm-pool-sandbox` label the moment a `SandboxClaim` binds it, so any
`NetworkPolicy` selecting that label stops applying at exactly the moment the sandbox begins
doing work.

It needs a stock `kubernetes-sigs/agent-sandbox` install and nothing else. No AWS, no
Firecracker, no gVisor, no model access, no MCP broker, no images to build.

> **Status: written, not executed.** These manifests were derived from the working
> equivalents in this repo's `platform/sandbox/` and from the live `kubectl explain` output of
> agent-sandbox v0.5.0's CRDs, but the reproducer as packaged here has not itself been run
> end to end. The behaviour it demonstrates *has* been observed repeatedly on the full stack
> (see the parent report's Evidence section).

## Prerequisites

- A Kubernetes cluster with `kubernetes-sigs/agent-sandbox` **v0.5.0** installed
  (controller + CRDs + `sandbox-router`). Steps 1-4 below need only the controller and CRDs.
- `kubectl` with access to that cluster.
- **For step 5 only** (the optional egress half): a CNI that actually enforces
  `NetworkPolicy`. Flannel + kube-router (k3s default) and the AWS VPC CNI with its
  network-policy agent both do. **kindnet does not** — it silently ignores NetworkPolicy, so
  on kind the egress observation is meaningless in both directions. Steps 1-4 are the
  load-bearing part of the reproducer and are CNI-independent.

## Files

| File | What it is |
|---|---|
| `00-namespace.yaml` | isolated namespace `repro-warmpool-label` |
| `10-sandboxtemplate.yaml` | minimal `SandboxTemplate`: busybox, default runtime, `networkPolicy.egress: []`, `podTemplate` label `repro-kind: sandbox` |
| `20-warmpool.yaml` | `SandboxWarmPool`, `replicas: 2` |
| `30-workshop-airgap-networkpolicy.yaml` | the workshop's supplemental air-gap policy, selector unchanged: `agents.x-k8s.io/warm-pool-sandbox` `Exists` |
| `40-claim.yaml` | a hand-written `SandboxClaim` — the event under test |

## Run it

### 1. Create the platform objects

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 10-sandboxtemplate.yaml
kubectl apply -f 20-warmpool.yaml
kubectl apply -f 30-workshop-airgap-networkpolicy.yaml

kubectl wait --for=condition=Ready pod --all -n repro-warmpool-label --timeout=180s
```

### 2. Observe the pooled state — the policy applies

```bash
kubectl get pod -n repro-warmpool-label --show-labels
```

Expected: two pods, **both** carrying `agents.x-k8s.io/warm-pool-sandbox=<hash>` alongside
`agents.x-k8s.io/sandbox-name-hash=<hash>` and `repro-kind=sandbox`.

Confirm the workshop policy is in fact selecting them:

```bash
kubectl get pod -n repro-warmpool-label \
  -l 'agents.x-k8s.io/warm-pool-sandbox' -o name
```

Expected: both pods listed. **This is the state in which the air gap is easy to verify, and
it is the state in which the workshop's verification steps are run.**

Note in passing that the controller's own generated policy selects a third label that no pod
here carries:

```bash
kubectl get networkpolicy -n repro-warmpool-label \
  -o custom-columns='NAME:.metadata.name,SELECTOR:.spec.podSelector'
kubectl get pod -n repro-warmpool-label \
  -l 'agents.x-k8s.io/sandbox-template-ref-hash' -o name    # expected: no resources found
```

### 3. Claim a sandbox

```bash
kubectl apply -f 40-claim.yaml

# which pod got bound
kubectl get sandboxclaim repro-claim -n repro-warmpool-label -o yaml | grep -A5 '^status:'
BOUND=$(kubectl get sandboxclaim repro-claim -n repro-warmpool-label \
          -o jsonpath='{.status.sandbox.name}')
echo "bound: $BOUND"
```

### 4. Observe the claimed state — the policy no longer applies

**This is the defect.**

```bash
kubectl get pod -n repro-warmpool-label --show-labels
```

Expected: the bound pod has **lost** `agents.x-k8s.io/warm-pool-sandbox` while keeping
`repro-kind=sandbox`. The other pod, still pooled, keeps both. (The pool may also have
started a replacement pod to return to `replicas: 2`; that one carries the label too.)

The selector comparison, stated as two commands:

```bash
# the workshop's selector — the claimed pod is MISSING from this list
kubectl get pod -n repro-warmpool-label -l 'agents.x-k8s.io/warm-pool-sandbox' -o name

# the template-supplied selector — the claimed pod IS in this list
kubectl get pod -n repro-warmpool-label -l 'repro-kind=sandbox' -o name
```

Or directly on the bound pod:

```bash
kubectl get pod "$BOUND" -n repro-warmpool-label \
  -o jsonpath='{.metadata.labels}' | tr ',' '\n'
```

A claimed sandbox carrying `repro-kind=sandbox` but not `agents.x-k8s.io/warm-pool-sandbox`
is the complete reproduction. Everything downstream — the unenforced air gap, the successful
outbound connection — follows from it.

### 5. Optional: show the egress consequence

Only meaningful on a NetworkPolicy-enforcing CNI. This runs a shell command inside the
claimed pod, so it does mutate cluster state in the ordinary `kubectl exec` sense.

```bash
# from the CLAIMED pod — expected to SUCCEED, because no policy selects it
kubectl exec -n repro-warmpool-label "$BOUND" -- \
  timeout 8 nc -z 1.1.1.1 443 && echo "CLAIMED POD REACHED THE INTERNET"

# CONTROL: from a still-POOLED pod — expected to FAIL, because the policy does select it
POOLED=$(kubectl get pod -n repro-warmpool-label \
           -l 'agents.x-k8s.io/warm-pool-sandbox' -o name | head -1)
kubectl exec -n repro-warmpool-label "$POOLED" -- \
  timeout 8 nc -z 1.1.1.1 443 || echo "POOLED POD BLOCKED (policy is being enforced)"
```

The pair matters. A "blocked" on its own is indistinguishable from a cluster with no egress
at all or a CNI that enforces nothing. Blocked *here* while reaching *there*, with the only
difference being one label, attributes the outcome to the selector.

## Clean up

```bash
kubectl delete namespace repro-warmpool-label
```

(The namespace delete removes the claim, pool, template, policy and pods. `40-claim.yaml`
sets `shutdownPolicy: Retain`, so a claimed pod outlives its claim — the namespace delete is
what actually reclaims it.)

## Expected vs actual, in one line

**Expected:** a policy applied to protect a sandbox protects it while it runs.
**Actual:** it protects it only while it is idle, because the selected label is a
pool-membership marker that the controller removes on claim.
