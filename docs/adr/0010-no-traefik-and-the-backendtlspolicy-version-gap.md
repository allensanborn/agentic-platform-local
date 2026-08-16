# ADR 0010 — Drop Traefik; and the cleartext hop is a version gap, not Traefik's fault

**Status:** accepted (Traefik removed); **the TLS hop is gone — option 1 was taken**
**Date:** 2026-08-16

> **Update.** The "Options" section below still reads as if the cleartext hop stays. It does not.
> Envoy Gateway was upgraded to **v1.8.1** — AI Gateway v1.0.0's documented minimum, so v1.5.6
> was never a supported pairing — which required the **Gateway API v1.5.0** CRD bundle first,
> because EG v1.8.x watches `ListenerSet` at `gateway.networking.k8s.io/v1`. `make cluster`
> installs both, in that order. The nginx TLS-origination sidecar
> (`platform/gateway/openrouter-tls-proxy.yaml`) was deleted;
> `platform/gateway/openrouter.yaml` now carries a `BackendTLSPolicy` with
> `wellKnownCACertificates: System`, so the gateway originates TLS to OpenRouter directly and
> verifies the certificate. The reasoning below is kept because the *cost* of option 1 was
> stated honestly before it was paid.

## Traefik is removed

k3s ships Traefik by default. Nothing in this stack uses it — **zero `Ingress` objects, no
Traefik `GatewayClass`**. It cost three pods and, more importantly, installed its own older
Gateway API CRDs beside Envoy Gateway's, leaving two versions of one API group in a cluster
whose entire point is Gateway-API-based routing.

Removed on the running cluster by deleting the `traefik` / `traefik-crd` HelmCharts and
dropping a `traefik.yaml.skip` file in the server's manifests directory (k3s re-applies the
packaged manifest otherwise). `make cluster` now passes `--disable=traefik@server:*` so a fresh
cluster never installs it. All 28 workload pods stayed Running through the removal, and the
Gateway API CRDs survived it.

## But Traefik was not causing the cleartext hop

ADR 0009 records that Envoy Gateway logged `BackendTLSPolicy CRD not found` and dialled
`openrouter.ai:443` in cleartext, worked around with an in-cluster nginx doing TLS origination,
and attributed that to Traefik owning the CRDs. Removing Traefik did not fix it, and the real
cause is more useful:

- `backendtlspolicies.gateway.networking.k8s.io` **is present**, and serves **`v1` only**
  (`v1alpha3: served=false`). Gateway API graduated the type in 1.4.
- **Envoy Gateway v1.5.6 watches `v1alpha3`.** So the CRD exists, the object applies cleanly at
  `v1`, and the controller simply never sees it: the policy got **no status at all** and Envoy
  Gateway logged nothing about it.

A resource that applies successfully and is then silently ignored is worse than one that fails,
because `kubectl apply` reports success. The tell was an **empty `.status.ancestors`** — a
Gateway API policy that no controller has claimed.

## Options, and why the hop stays for now

1. **Upgrade Envoy Gateway** (v1.6.x / v1.7.0 exist) so it understands `v1`. Most likely the
   real fix. Not taken unprompted: Envoy Gateway v1.5.6 + AI Gateway v1.0.0 is a pairing that
   took real effort to get right (see ADR 0002 — the `extensionManager` values), and every lab
   from 0 to 7 runs through it. An unforced upgrade risks the whole stack to remove one
   in-cluster cleartext hop.
2. **Downgrade the Gateway API CRD bundle** to one still serving `v1alpha3`. Fixes this and
   breaks anything expecting `v1`. Worse trade.
3. **Keep the nginx TLS-origination hop** (current). The OpenRouter key still lives only with
   the gateway tier; what is exposed is one hop *inside* the cluster, on a laptop. Explicitly
   not production-shaped, and labelled as such.

Option 1 is the right move when someone has appetite to re-verify labs 0-7 afterwards. Until
then the honest statement is: **the cleartext hop is a known, contained, documented compromise
with a known fix**, not an unexplained wart.

## Method note

Two diagnoses in a row blamed the wrong component — Envoy for the missing spans (ADR 0004,
actually a `appProtocol`/HTTP-2 gap) and Traefik here (actually an apiVersion gap). Both times
the wrong suspect was the one that had caused trouble before. Check what the API server
actually serves (`kubectl get crd <name> -o jsonpath='{.spec.versions[*].name}'`) before
blaming a component for ignoring a resource.
