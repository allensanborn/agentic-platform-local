# Defect 002 — `a2a-authn.yaml` targets `spec.authorization`, which does not exist; module 800 cannot be applied as written

**Severity: medium (correctness / bit-rot). Not a security defect — it fails closed.**
**Status: reproduced with `kubectl apply --dry-run=server` against agentgateway-crds 1.4.1.**
**Tracking:** beads `llm-wiki-661.18`.

## One-line statement

`800-multi-agent-authz/policies/a2a-authn.yaml` places its `Require` rule at `spec.authorization`. That field does not exist in `AgentgatewayPolicy` `v1alpha1`; the HTTP-level authorization block lives at `spec.traffic.authorization`. The manifest is **rejected** by the API server, so lab 800 cannot be completed by following its own instructions.

## Read this first — an earlier characterization of ours was wrong

We initially filed this as a second *fail-open* defect: unknown field on a structural schema without `x-kubernetes-preserve-unknown-fields` implies pruning, therefore the object would be created, report no error, and gate nothing.

**That was wrong, and measurement corrected it.** The manifest is rejected under both validation paths (see Evidence). No one gets a false sense of enforcement. If you have seen this defect described as fail-open — including in earlier revisions of our own notes — that description is retracted.

What remains is real but narrower: **the shipped manifest does not apply, so the lab is unfollowable as written.**

## Affected artifacts

| Path | Role |
|---|---|
| `800-multi-agent-authz/policies/a2a-authn.yaml` | **The defect.** Both documents (`order-agent-a2a-authn`, `product-agent-a2a-authn`) put the rule at `spec.authorization`. |
| `800-multi-agent-authz/README.md:53` | Describes the intended behaviour: "`authorization: action Require, has(jwt.sub)`". The intent is correct; only the path is wrong. |

Component version measured against: **agentgateway-crds 1.4.1** (Helm release `agentgateway-crds`, chart `agentgateway-crds-1.4.1`, app version 1.4.1, CRD generated with `controller-gen.kubebuilder.io/version: v0.20.0`), on Kubernetes server v1.35.5+k3s1 with kubectl client v1.33.9.

We do not know which agentgateway version the workshop was authored against. It is plausible `spec.authorization` was valid in an earlier release and the field moved under `spec.traffic`; we have not verified that, so we describe this as bit-rot without asserting when it broke.

## Expected vs actual

**Expected:** applying `policies/a2a-authn.yaml` creates two `AgentgatewayPolicy` objects that require a validated JWT subject on the `order-agent-a2a` and `product-agent-a2a` HTTPRoutes.

**Actual:** `kubectl apply` fails. Neither object is created. The lab's subsequent verification steps have nothing to verify.

## Evidence

Both runs below are `--dry-run=server`, so nothing was mutated. Real captured output, 2026-08-17.

### Path 1 — default strict decoding (kubectl >= 1.27)

```
$ kubectl apply --dry-run=server -f 800-multi-agent-authz/policies/a2a-authn.yaml
Error from server (BadRequest): error when creating ".../a2a-authn.yaml": AgentgatewayPolicy in version "v1alpha1" cannot be handled as a AgentgatewayPolicy: strict decoding error: unknown field "spec.authorization"
Error from server (BadRequest): error when creating ".../a2a-authn.yaml": AgentgatewayPolicy in version "v1alpha1" cannot be handled as a AgentgatewayPolicy: strict decoding error: unknown field "spec.authorization"
# exit 1
```

(One error per document in the file.)

### Path 2 — lenient decoding, the path on which pruning *would* occur

```
$ kubectl apply --dry-run=server --validate=ignore -f 800-multi-agent-authz/policies/a2a-authn.yaml
Error from server (Invalid): error when creating ".../a2a-authn.yaml": AgentgatewayPolicy.agentgateway.dev "order-agent-a2a-authn" is invalid: spec: Invalid value: At least one of traffic, frontend, or backend must be provided.
Error from server (Invalid): error when creating ".../a2a-authn.yaml": AgentgatewayPolicy.agentgateway.dev "product-agent-a2a-authn" is invalid: spec: Invalid value: At least one of traffic, frontend, or backend must be provided.
# exit 1
```

This is the important half. Even when the unknown field **is** pruned, a CEL required-oneof validation rule on the CRD rejects the resulting empty `spec`. The pruning path is backstopped. **Fail-closed both ways.**

### The correct path exists and carries exactly the intended semantics

```
$ kubectl explain agentgatewaypolicy.spec.traffic.authorization
GROUP:      agentgateway.dev
KIND:       AgentgatewayPolicy
VERSION:    v1alpha1

FIELD: authorization <Object>

DESCRIPTION:
    Access rules based on roles and permissions. ...

FIELDS:
  action	<string>
  enum: Allow, Deny, Require
    ...
  policy	<Object> -required-
    ...
```

`AgentgatewayPolicy.spec` in 1.4.1 has exactly `[backend, frontend, strategy, targetRefs, targetSelectors, traffic]`. There is no top-level `authorization`.

## Impact

- **Lab 800 is unfollowable as written** against current agentgateway. A reader copying the manifest gets two errors and no policy.
- **No security exposure.** The failure is loud and closed. This is a correctness bug, not a vulnerability, and it should not be reported as one.
- Recovery is cheap for a reader who reads the error, but the error message (`unknown field "spec.authorization"`) does not tell them where the field moved to, so it costs a schema dig.

**Severity: medium.** Blocks a published lab; no security consequence.

## Suggested fix

Move both rules one level down, under `spec.traffic`:

```yaml
spec:
  targetRefs:
    - kind: HTTPRoute
      name: order-agent-a2a
      group: gateway.networking.k8s.io
  traffic:
    authorization:
      action: Require
      policy:
        matchExpressions:
          - 'has(jwt.sub)'
```

Same change for the `product-agent-a2a-authn` document. Nothing else in the file needs to change — the CEL expression `has(jwt.sub)` is unaffected.

Additionally: pin the agentgateway chart version the module is validated against in `800-multi-agent-authz/README.md`, so the next schema move is diagnosable rather than mysterious.

The corrected version, with a header explaining the delta, is `modules/800-a2a-authz/policies/a2a-authn.yaml` in this repo.

## What we did not verify

- **Which agentgateway version the workshop was written against**, and therefore whether `spec.authorization` was ever a valid path. We assert only that it is invalid in 1.4.1.
- We did not test intermediate agentgateway versions to find where the field moved.
- We did not verify runtime enforcement of the corrected policy end-to-end as part of *this* report; the claim here is confined to admission (`--dry-run=server`) behaviour.
- We did not use a non-kubectl client (which is what would actually send a lenient request in practice). `--validate=ignore` is our stand-in for that path.
