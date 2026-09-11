# 060 — OpenBao secrets plane

**Seam:** `secrets` · **Status:** proposed
**Base required:** labs 0-7 (the dispatcher is the star)
**Requires extensions:** none
**Alternative to:** raw K8s Secrets (same seam)

## What this demonstrates

Module 1000's dispatcher already implements dynamic secrets *by hand*: mint a per-run Gitea token, revoke in a `finally`. This extension moves that pattern — and the static secrets around it (`coding-agent-creds`, Langfuse's) — behind **OpenBao**, the Linux Foundation fork of Vault that now ships Enterprise-grade features (namespaces, HSM auto-unseal, Transform) under an OSI license. The dispatcher stops holding the bot password at all: it holds a short-lived OpenBao token (or, composed with 040, authenticates via its SVID) and asks for a lease.

The control point: the lease. Every credential in the system becomes revocable-by-TTL from one place, and "revoke everything this workload was issued" is one command instead of an audit.

## The substitution

| | Base | This extension |
|---|---|---|
| `secrets` | K8s Secrets + hand-rolled mint/revoke in `gitea_client.py` | OpenBao: static KV mounts for config, a custom/database-style secrets engine (or a thin plugin) issuing leased Gitea tokens |

Preserved: the dispatcher's flow and module 1000's four guarantees — no human PAT, no standing sandbox credential, locked egress, isolation. Cost: OpenBao itself, K8s auth method config, and the honest note that a bespoke Gitea secrets engine is a small development task (the fallback — KV + dispatcher-driven revocation — keeps the lease semantics with less purity).

## Plan

1. OpenBao on the cluster, K8s auth method bound to the dispatcher's ServiceAccount (or 040's SVID).
2. Migrate static secrets first (Langfuse, webhook secret) — boring, low-risk, proves the mount.
3. The lease demo: per-run Gitea token issued as a lease; `make coding-token-check`'s mint → 200 → revoke → 401 sequence reproduced with OpenBao doing the revoking.
4. Verify + controls.

## Verify

- `kubectl get secret` shows the migrated secrets gone from the cluster
- lease expiry: let a token's TTL lapse and show the 401 arrives *without anyone revoking* — the property the hand-rolled version never had
- **positive control:** an unexpired lease still authenticates
- kill test from ADR habit: OpenBao down → coding runs fail loudly at mint time, never fall back to a cached credential

## Grounding

wiki: `openbao` (fork history; 2.5/2.6 ahead-of-Vault status), `zero-trust`; module 1000's README limit table (the mint/revoke rows this formalizes).
