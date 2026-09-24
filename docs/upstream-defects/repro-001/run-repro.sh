#!/usr/bin/env bash
# run-repro.sh <agent-sandbox-tag>            e.g.  ./run-repro.sh v0.5.0
# run-repro.sh <core-yaml> <ext-yaml> <label> e.g.  ./run-repro.sh core.yaml ext.yaml local
#
# Runs repro-001 end to end, unattended, against one agent-sandbox version, and prints a
# transcript to stdout. It recreates a throwaway k3d cluster named `repro001` first, so a
# version matrix is just a `for` loop over tags and no run can be contaminated by the last
# one. The transcripts in evidence/transcripts/ were produced by this script.
#
# Every deny it prints is paired with a control that must succeed — see step 0 and step 5.
#
# Needs: k3d, kubectl, and (for the tag form) gh with access to github.com.
set -uo pipefail

R=$(cd "$(dirname "$0")" && pwd)
NS=repro-warmpool-label

if [ $# -eq 1 ]; then
  LABEL=$1
  DL=$(mktemp -d)
  gh release download "$LABEL" -R kubernetes-sigs/agent-sandbox -D "$DL" --clobber >/dev/null || exit 1
  # v0.5.0 and v0.5.1 name the core asset manifest.yaml; v0.5.2+ renamed it sandbox.yaml.
  CORE=$DL/sandbox.yaml; [ -f "$CORE" ] || CORE=$DL/manifest.yaml
  EXT=$DL/extensions.yaml
else
  CORE=$1; EXT=$2; LABEL=$3
fi

echo "################ RUN: $LABEL ################"
echo "core: $CORE"
echo "ext:  $EXT"
date -u +'run started %Y-%m-%dT%H:%M:%SZ'

k3d cluster delete repro001 >/dev/null 2>&1
k3d cluster create repro001 --agents 1 --wait --k3s-arg "--disable=traefik@server:*" >/dev/null 2>&1 || exit 1
kubectl config use-context k3d-repro001 >/dev/null

echo
echo "===== STEP 0: CNI pre-check ====="
kubectl apply -f "$R/05-cni-precheck.yaml" >/dev/null
kubectl wait --for=condition=Ready pod --all -n repro-cni-precheck --timeout=180s >/dev/null
echo -n "control (unselected, must REACH): "
kubectl exec -n repro-cni-precheck control -- timeout 8 nc -zv -w 5 1.1.1.1 443 2>&1; echo "  exit=$?"
echo -n "selected (deny-all, must BLOCK): "
kubectl exec -n repro-cni-precheck selected -- timeout 8 nc -zv -w 5 1.1.1.1 443 2>&1; echo "  exit=$?"

echo
echo "===== install control plane ====="
kubectl apply --server-side -f "$CORE" >/dev/null || { echo "CORE APPLY FAILED"; kubectl apply --server-side -f "$CORE"; }
kubectl apply --server-side -f "$EXT"  >/dev/null || { echo "EXT APPLY FAILED";  kubectl apply --server-side -f "$EXT"; }
kubectl wait --for=condition=Established --timeout=120s \
  crd/sandboxes.agents.x-k8s.io \
  crd/sandboxtemplates.extensions.agents.x-k8s.io \
  crd/sandboxwarmpools.extensions.agents.x-k8s.io \
  crd/sandboxclaims.extensions.agents.x-k8s.io >/dev/null
kubectl wait --for=condition=Available --timeout=300s -n agent-sandbox-system deploy --all
echo -n "controller image: "
kubectl get deploy -n agent-sandbox-system -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}'

echo
echo "===== STEP 1: apply platform objects ====="
kubectl apply -f "$R/00-namespace.yaml" -f "$R/10-sandboxtemplate.yaml" \
              -f "$R/20-warmpool.yaml" -f "$R/30-workshop-airgap-networkpolicy.yaml"
for i in $(seq 40); do
  [ "$(kubectl get pod -n $NS --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] && break
  sleep 2
done
kubectl wait --for=condition=Ready pod --all -n $NS --timeout=180s

echo
echo "===== STEP 2: pooled state ====="
kubectl get pod -n $NS --show-labels
echo "-- pods selected by the workshop policy (warm-pool-sandbox):"
kubectl get pod -n $NS -l 'agents.x-k8s.io/warm-pool-sandbox' -o name
echo "-- networkpolicies:"
kubectl get networkpolicy -n $NS -o custom-columns='NAME:.metadata.name,SELECTOR:.spec.podSelector'
echo "-- PODS carrying sandbox-template-ref-hash:"
kubectl get pod -n $NS -l 'agents.x-k8s.io/sandbox-template-ref-hash' -o name 2>&1
echo "-- SANDBOX CRs carrying sandbox-template-ref-hash:"
kubectl get sandbox -n $NS -l 'agents.x-k8s.io/sandbox-template-ref-hash' -o name 2>&1
echo "-- sandbox CR labels:"
kubectl get sandbox -n $NS --show-labels

echo
echo "===== STEP 3: claim ====="
kubectl apply -f "$R/40-claim.yaml"
for i in $(seq 30); do
  B=$(kubectl get sandboxclaim repro-claim -n $NS -o jsonpath='{.status.sandbox.name}' 2>/dev/null)
  [ -n "$B" ] && break
  sleep 2
done
kubectl get sandboxclaim -n $NS
BOUND=$(kubectl get sandboxclaim repro-claim -n $NS -o jsonpath='{.status.sandbox.name}')
echo "BOUND=$BOUND"
sleep 8

echo
echo "===== STEP 4: claimed state ====="
kubectl get pod -n $NS --show-labels
echo "-- bound pod labels:"
kubectl get pod "$BOUND" -n $NS -o jsonpath='{.metadata.labels}'; echo
echo "-- bound SANDBOX CR labels:"
kubectl get sandbox "$BOUND" -n $NS -o jsonpath='{.metadata.labels}'; echo
echo "-- workshop selector (warm-pool-sandbox) -> is BOUND in this list?"
kubectl get pod -n $NS -l 'agents.x-k8s.io/warm-pool-sandbox' -o name
echo "-- template-supplied selector (repro-kind=sandbox):"
kubectl get pod -n $NS -l 'repro-kind=sandbox' -o name
echo "-- generated-policy selector (sandbox-template-ref-hash) on PODS:"
kubectl get pod -n $NS -l 'agents.x-k8s.io/sandbox-template-ref-hash' -o name 2>&1
echo "-- networkpolicies now:"
kubectl get networkpolicy -n $NS -o custom-columns='NAME:.metadata.name,SELECTOR:.spec.podSelector'

echo
echo "===== STEP 5: egress ====="
echo "-- CLAIMED pod ($BOUND):"
kubectl exec -n $NS "$BOUND" -- sh -c 'timeout 8 nc -zv -w 5 1.1.1.1 443 2>&1; echo "  nc exit=$?"'
POOLED=$(kubectl get pod -n $NS -l 'agents.x-k8s.io/warm-pool-sandbox' -o name | head -1); POOLED=${POOLED#pod/}
echo "-- CONTROL, still-POOLED pod ($POOLED):"
kubectl exec -n $NS "$POOLED" -- sh -c 'timeout 8 nc -zv -w 5 1.1.1.1 443 2>&1; echo "  nc exit=$?"'
echo "-- CONTROL, pod in a namespace with no sandbox policy (repro-cni-precheck/control):"
kubectl exec -n repro-cni-precheck control -- sh -c 'timeout 8 nc -zv -w 5 1.1.1.1 443 2>&1; echo "  nc exit=$?"'

echo
echo "===== STEP 5b: attribution — delete the workshop policy, re-probe the claimed pod ====="
kubectl delete -f "$R/30-workshop-airgap-networkpolicy.yaml" >/dev/null
sleep 5
kubectl exec -n $NS "$BOUND" -- sh -c 'timeout 8 nc -zv -w 5 1.1.1.1 443 2>&1; echo "  nc exit=$?"'

echo
echo "===== STEP 5c: POSITIVE CONTROL — same setup, template egress flipped to allow-all ====="
# Deleting the generated policy proves nothing: the controller recreates it within seconds.
# Flip the one field that is under test instead, in a second namespace, and check the sign
# of the result reverses.
kubectl apply -f "$R/50-openegress-template.yaml" >/dev/null
for i in $(seq 40); do
  n=$(kubectl get pod -n repro-openegress --no-headers 2>/dev/null | grep -c ' Running ')
  [ "${n:-0}" -ge 2 ] && break
  sleep 2
done
kubectl apply -f "$R/60-openegress-claim.yaml" >/dev/null
for i in $(seq 30); do
  BOPEN=$(kubectl get sandboxclaim repro-claim-open -n repro-openegress -o jsonpath='{.status.sandbox.name}' 2>/dev/null)
  [ -n "$BOPEN" ] && break
  sleep 2
done
sleep 8
BOPEN=$(kubectl get sandboxclaim repro-claim-open -n repro-openegress -o jsonpath='{.status.sandbox.name}')
echo "BOPEN=$BOPEN  (must be a repro-pool-open-* name; a 'repro-claim-open' name means it"
echo "              cold-started instead of adopting, and the control does not count)"
kubectl get pod -n repro-openegress --show-labels
kubectl get networkpolicy -n repro-openegress -o custom-columns='NAME:.metadata.name,SELECTOR:.spec.podSelector'
echo "-- CLAIMED pod under an allow-all template policy (must REACH):"
kubectl exec -n repro-openegress "$BOPEN" -- sh -c 'timeout 8 nc -zv -w 5 1.1.1.1 443 2>&1; echo "  nc exit=$?"'

date -u +'run finished %Y-%m-%dT%H:%M:%SZ'
echo "################ END: $LABEL ################"
