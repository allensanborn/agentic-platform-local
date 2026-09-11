# 040 — SPIFFE/SPIRE workload identity

**Seam:** `identity` (the workload half — composes with 010/020, which own the *user* half) · **Status:** proposed
**Base required:** labs 0-4
**Requires extensions:** none
**Alternative to:** none

## What this demonstrates

The deck's control point #1 is "Credentials: the agent holds none," implemented upstream with EKS Pod Identity — AWS attests the pod and injects short-lived credentials. The base port kept the *posture* (no mounted ServiceAccount token in the sandbox) but has no positive workload identity at all: services trust each other because they share a cluster. This extension installs **SPIRE** and gives every workload an attested, auto-rotating **SVID** — agent, MCP server, broker, gateways — with mTLS between them. No secret is mounted anywhere; identity is attested (node + workload attestation), not distributed.

The control point: the trust anchor. A workload that cannot attest gets no identity, and a workload identity expires in minutes — there is nothing long-lived to steal.

## The substitution

| | Base | This extension |
|---|---|---|
| workload trust | shared cluster network + K8s Secrets | SPIRE-issued X.509/JWT SVIDs via the Workload API, mTLS everywhere |

Preserved: everything user-facing; personas and tool authz are untouched (that is the user half of the seam). Cost: SPIRE server + agents (~modest), and each hop's client/server config learns to speak the Workload API or sit behind an mTLS-terminating sidecar.

## Plan

1. SPIRE server + agent on k3s; registration entries for the base workloads; watch SVIDs rotate.
2. mTLS the quietest hop first (broker → MCP server), then work outward toward the gateways.
3. Optional bridge worth demoing: a JWT-SVID as the `subject_token` into 010's exchange — attested workload identity feeding the OAuth chain (the pattern Dapr 1.16's Sentry-as-OIDC-issuer normalized).
4. Verify + controls.

## Verify

- an unregistered pod gets nothing from the Workload API (and the hop refuses it)
- **positive control:** a registered control pod on the same node fetches an SVID and connects
- rotate: kill a SPIRE agent, watch SVIDs expire and connections fail *loudly*, not silently persist

## Grounding

wiki: `spiffe-spire` (incl. the AWS EKS Nested-SPIRE guide — the upstream-mapped version of this extension), `service-identity`, `zero-trust` (NIST 800-207 PEP framing), `dapr-diagrid-service-identity`.
