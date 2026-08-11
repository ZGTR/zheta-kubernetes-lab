#!/usr/bin/env bash
source "$(dirname "$0")/istio-ambient-lib.sh"
require_mesh_context
scope="${1:-forge}"
[ "$scope" = control-plane ] || [ "$scope" = forge ] || { echo 'usage: verify-istio-ambient.sh [control-plane|forge]' >&2; exit 1; }

kubectl --context "$MESH_CONTEXT" get crd gateways.gateway.networking.k8s.io >/dev/null
kubectl --context "$MESH_CONTEXT" -n istio-system rollout status deployment/istiod --timeout=180s
kubectl --context "$MESH_CONTEXT" -n istio-system rollout status daemonset/istio-cni-node --timeout=180s
kubectl --context "$MESH_CONTEXT" -n istio-system rollout status daemonset/ztunnel --timeout=180s
[ "$scope" = control-plane ] && exit 0

[ "$(kubectl --context "$MESH_CONTEXT" get namespace zheta-forge -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')" = ambient ]
[ "$(kubectl --context "$MESH_CONTEXT" get namespace zheta-forge -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')" = forge-waypoint ]
kubectl --context "$MESH_CONTEXT" -n zheta-forge wait gateway/forge-waypoint --for=condition=Accepted --timeout=180s
kubectl --context "$MESH_CONTEXT" -n zheta-forge wait gateway/forge-waypoint --for=condition=Programmed --timeout=180s
kubectl --context "$MESH_CONTEXT" -n zheta-forge rollout status deployment/forge-waypoint --timeout=180s
[ "$(kubectl --context "$MESH_CONTEXT" -n zheta-forge get peerauthentication forge-strict-mtls -o jsonpath='{.spec.mtls.mode}')" = STRICT ]
kubectl --context "$MESH_CONTEXT" -n zheta-forge get authorizationpolicy allow-only-destination-waypoint generator-from-control-plane runtime-from-control-plane evidence-from-control-plane broker-from-publishers >/dev/null
for service_account in control-plane generator runtime evidence broker; do
  kubectl --context "$MESH_CONTEXT" -n zheta-forge get serviceaccount "$service_account" >/dev/null
done
for policy in control-plane-paths internal-services broker-publish-subscribe forge-waypoint allow-ambient-kubelet-health-probes; do
  kubectl --context "$MESH_CONTEXT" -n zheta-forge get networkpolicy "$policy" >/dev/null
done
verify_mesh_product_policy
echo 'Ambient enrollment, waypoint, identities, mTLS, authorization, and NetworkPolicy objects are present. Live denial and mTLS telemetry remain separate evidence gates.'
