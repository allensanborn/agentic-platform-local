# ADR 0001 — k3s (via k3d), not kind

**Status:** accepted
**Date:** 2026-08-15

## Decision

Use **k3d** (k3s in Docker) as the local cluster, not kind — even though kind was already
installed.

## Why

**kindnet does not enforce NetworkPolicy** ([kind#842](https://github.com/kubernetes-sigs/kind/issues/842)).
Lab 5's entire isolation demonstration is a NetworkPolicy with `egress: []` — which the
workshop's own text is careful to explain means "no destination is permitted", not "no
rules configured". On kind that object applies cleanly, reports healthy, and enforces
nothing.

That is the worst available failure mode for a teaching artifact: the demo would *look*
like it worked. A sandbox that appears air-gapped and is not is worse than no sandbox,
because it produces confident wrong beliefs.

k3s ships a NetworkPolicy controller enabled by default.

## Consequence

One extra dependency (`k3d`). Lab 5's airgap can be verified rather than assumed.
