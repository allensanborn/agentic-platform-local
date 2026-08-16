# ADR 0011 — the agent-to-agent hop is the least governed hop in the stack

**Status:** accepted (the finding); **implementation UNVERIFIED — see "What is not verified"**
**Date:** 2026-08-16

## Context

Modules 600 and 800 of the workshop add a third hop to the platform. Until now there were two:

```
client -> [Envoy AI Gateway] -> model          (lab 0)
agent  -> [agentgateway/MCP] -> tools          (labs 3-4)
```

Multi-agent adds one in the middle:

```
UI -> orchestrator -> [agentgateway A2A] -> order-agent -> [agentgateway MCP] -> mcp-server
```

The same proxy sits in front of both the A2A hop and the MCP hop. The identical placement makes
it easy to assume identical capability. It is not.

## Decision

Implement modules 600 + 800 as the workshop specifies — A2A routes through agentgateway with a
route-grain `Require: has(jwt.sub)` gate — and **document the asymmetry as a finding rather than
quietly matching it**, because a reader who sees "agentgateway is in front of both hops" will
otherwise conclude that both hops are governed the same way.

## The asymmetry

| | MCP hop (labs 3-4) | A2A hop (modules 600/800) |
|---|---|---|
| Policy location | `AgentgatewayPolicy.spec.backend.mcp.authorization` | `AgentgatewayPolicy.spec.traffic.authorization` |
| Grain | per **tool** | per **route** |
| Predicates available | `mcp.tool.name`, `jwt[...]` | HTTP-level facts + `jwt[...]` |
| Effect on discovery | unauthorized tools are **filtered out of `tools/list`** | none — there is no list to filter |
| Best rule expressible | "only support-associate may `initiate_return`" | "the caller is somebody" |

So `sam` cannot call `check_inventory` — the tool does not appear in his `tools/list` at all —
but `sam` can open a JSON-RPC session with the **product agent**, send it any text he likes, and
get its `search_products` tool run on his behalf. Not because a rule permits it: because there
is no rule to write.

`search_products` makes the point sharper than the workshop's own framing does. It is an
in-process Strands `@tool`, not an MCP tool. It never crosses agentgateway, so no policy in this
cluster can see it, let alone authorize it. **The only control in front of it is the
route-grain authn on the A2A hop** — a gate that admits every authenticated user in the realm.

Generalized: an agent's *reachability* is the union of every tool it holds. Gating the hop at
"authenticated" grants the caller that whole union. The per-tool authorization work done in lab
4 is scoped to one agent's own MCP calls; it says nothing about what a *second* agent will do
when asked. And what a second agent does is decided by a language model reading attacker-supplied
text.

Concretely, with only this gate in place:

- Any workload holding any valid realm token — a compromised pod, a stolen browser token, a
  developer with `curl` — can drive **either** specialist directly. The orchestrator is not a
  required participant; it is merely the usual one.
- A prompt-injected orchestrator can delegate anything to anyone. "Confused deputy" is not a
  hypothetical here, it is the design: the orchestrator's job is to forward attacker-influenced
  text to a more privileged agent.
- The blast radius runs the wrong way. The hop with the widest reach (a whole agent, with all
  its tools and its own judgment) has the coarsest control; the hop with the narrowest reach (one
  named tool call) has the finest.

## Is this a workshop choice or an agentgateway limitation?

**An agentgateway limitation.** The workshop's own 800 README says so ("agentgateway has no
per-A2A-method authz — the backend policy has mcp/ai sub-keys, no a2a"), and the CRD schema
confirms it.

Evidence, read from the **CRD chart on disk** — `agentgateway-crds` **1.4.1** from the local
Helm cache (`~/Library/Caches/helm/repository/agentgateway-crds-1.4.1.tgz`), not from
`kubectl explain`, because the cluster was down when this was written:

```
AgentgatewayBackend.spec  : [a2a, ai, aws, dynamicForwardProxy, mcp, policies, static]
AgentgatewayPolicy.spec   : [backend, frontend, strategy, targetRefs, targetSelectors, traffic]
AgentgatewayPolicy.spec.backend :
    [ai, auth, extAuth, health, http, mcp, tcp, tls, transformation, tunnel]
```

`a2a` is a first-class **backend** type (`{host, port}`) and is absent from the **policy**
backend block. The protocol can be routed and cannot be governed. Only `backend.mcp` carries
`authorization`, and its own description states the item-level semantics that make lab 4 work:

> "List operations, such as `list_tools`, will have each item evaluated. Items that do not meet
> the rule will be filtered."

Nothing equivalent exists for A2A's `message/send`, `tasks/get`, `tasks/cancel`, or for agent
skills. The string `a2a` does not appear anywhere in the `agentgateway` 1.4.1 chart outside the
backend type itself.

Re-check when upgrading agentgateway:

```bash
kubectl explain agentgatewaypolicy.spec.backend | grep -E '^\s+a2a\b'   # expect: no match
make a2a-verify                                                         # prints the same check
```

`make a2a-verify` says "PRESENT — this finding has expired, update ADR 0011" if that ever
changes.

## A second finding, found while porting

The workshop's `800-multi-agent-authz/policies/a2a-authn.yaml` puts the rule at
**`spec.authorization`**. That field **does not exist** in `AgentgatewayPolicy` v1alpha1 as
shipped in agentgateway-crds 1.4.1; the HTTP-level block is `spec.traffic.authorization`. The
spec schema is structural, with no `x-kubernetes-preserve-unknown-fields`, so the workshop's
document is an unknown-field write: rejected under strict field validation, **silently pruned**
under the permissive kind — leaving an `AgentgatewayPolicy` object that exists, reports no error,
and gates nothing.

That is the third time this repo has been bitten by the same shape (ADR 0010's ignored
`BackendTLSPolicy`; the stale ConfigMap behind a broken YAML comment). The local port uses
`spec.traffic.authorization`. Whether the workshop is written against a newer or older CRD, or
is simply wrong, is not determinable from here.

## Consequences

- Modules 600 + 800 ship as the workshop designs them, with the honest label: **A2A is
  authenticated, not authorized.**
- The demo does not pretend otherwise. `make a2a-verify` prints `sam` and `ana` both reaching
  both specialists and calls that a pass, and `make a2a-bypass` shows the Service answering with
  no token at all when the gateway is stepped around — a gate is only a gate if it is the only
  path.
- What would actually close the gap, none of it available in the CRD today:
  1. per-method / per-skill A2A authorization at the gateway (`a2a.method`, `a2a.skill.id`);
  2. failing that, **NetworkPolicy** so only the orchestrator's pod may open a connection to a
     specialist, which turns "any authenticated caller" into "the orchestrator, authenticated" —
     coarse, but it removes the direct-dial path `make a2a-bypass` demonstrates;
  3. token **exchange** (RFC 8693) at the delegation boundary instead of forwarding the user's
     token verbatim, so the downstream agent receives a narrowed audience and scope rather than
     the caller's full rights. The workshop names this as a production delta and does not do it;
     neither does this port.
- The wiki's two-hop control-point model becomes a three-hop model, with the middle hop marked
  as the weak one.

## What is not verified

The Docker engine on the host was hung for the duration of this work (`docker ps` returned
nothing at a 90-second timeout; `kubectl` failed with `net/http: TLS handshake timeout`), so
**nothing in modules 600/800 has been built, deployed, or run.** Verified offline: Python and
Bash syntax; YAML parse; and JSON-schema validation of both `AgentgatewayPolicy` and both
`AgentgatewayBackend` documents against the 1.4.1 CRD schemas, including a check that no field
would be pruned. The finding in this ADR rests on the CRD schema and the workshop's own README,
neither of which needs a running cluster.

Still to confirm when the cluster returns: the images build; the specialists come up; the
`a2a` backend type routes with the `URLRewrite`; the `Require` rule really produces 401; the
persona reaches `mcp-server` across both hops (the tool list the order-agent logs is the
deterministic check); and whether the installed CRD version matches the 1.4.1 read here.
