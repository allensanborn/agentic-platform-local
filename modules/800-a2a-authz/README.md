# Module 800 — authn at the A2A hop, and the authorization gap behind it

> **Status: written, NOT yet applied.** The cluster was unreachable while this was built
> (hung Docker engine). The policy documents were validated against the CRD schema offline; they
> have not been applied. See [module 600's README](../600-a2a/README.md#verification-status).

Local port of the workshop's `800-multi-agent-authz`. One file:
`policies/a2a-authn.yaml`, two `AgentgatewayPolicy` objects, one per specialist route.

```bash
make a2a-authz     # kubectl apply -f policies/a2a-authn.yaml
```

## What it does

Lab 4's `mcp-authn` policy targets the **Gateway**, so the A2A routes are already authenticated
the moment they exist. This adds the deny-unauthenticated gate:

```yaml
traffic:
  authorization:
    action: Require
    policy:
      matchExpressions:
        - 'has(jwt.sub)'
```

`Require` rules are cumulative and this one passes only when a validated JWT subject is present.
No token is a 401 at the gateway, before any agent code runs.

## What it deliberately does not do

Differentiate. **Any authenticated persona may reach any specialist.** That is not laziness in
the policy; there is nothing else to write. `AgentgatewayPolicy.spec.backend` has sub-keys
`[ai, auth, extAuth, health, http, mcp, tcp, tls, transformation, tunnel]` and **no `a2a`**, so
there is no `a2a.method`, no `a2a.skill.id`, no per-agent capability rule. The rule you would
want, and cannot write:

```yaml
# NOT VALID — no such thing. Kept as a statement of the gap.
backend:
  a2a:
    authorization:
      action: Allow
      policy:
        matchExpressions:
          - 'a2a.skill.id == "orders" && "support-associate" in jwt["groups"]'
```

Compare the MCP hop, where exactly that grain exists and lab 4 uses it
(`mcp.tool.name == "initiate_return" && "support-associate" in jwt["groups"]`).

The consequence, and why it is worth a whole ADR: the hop with the **widest** reach — a whole
agent, with all its tools and its own judgment about attacker-supplied text — has the
**coarsest** control. Full argument, evidence from the CRD schema, and what would close the gap:
[ADR 0011](../../docs/adr/0011-a2a-is-the-least-governed-hop.md).

## One port change, and it is not an AWS one

The workshop puts the rule at `spec.authorization`. **That field does not exist** in
`AgentgatewayPolicy` v1alpha1 as shipped in agentgateway-crds 1.4.1 — the HTTP-level block is
`spec.traffic.authorization`. The spec schema is structural with no
`x-kubernetes-preserve-unknown-fields`, so the workshop's document is an unknown-field write:
rejected under strict field validation, silently pruned under the permissive kind. The pruned
case is the dangerous one — a policy object that exists, reports no error, and gates nothing.

## Test matrix

`make a2a-verify` runs this and prints it as a table.

| Case | Expected | Meaning |
|---|---|---|
| no token -> either specialist | **401** | the Require rule is enforcing |
| `sam` -> order-agent | 200 | authenticated is sufficient |
| `sam` -> product-agent | 200 | ...for *any* specialist. This is the finding, not a bug |
| `ana` -> product-agent | 200 | same |
| no token, straight at the Service (`make a2a-bypass`) | 200 | a gate is only a gate if it is the only path |
| `sam` vs `ana` tool list at the MCP hop (`make a2a-hops`) | differs | identity survived both hops; differentiation still lives at the MCP layer |

Distinguishing the two failure modes matters: **401 = A2A authn** (this module), **403 or a
vanished tool = MCP authz** (lab 4).
