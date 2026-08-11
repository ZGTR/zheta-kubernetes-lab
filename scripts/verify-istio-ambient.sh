#!/usr/bin/env bash
source "$(dirname "$0")/istio-ambient-lib.sh"
require_mesh_context
scope="${1:-l7}"
[ "$scope" = control-plane ] || [ "$scope" = enrollment ] || [ "$scope" = l4 ] || [ "$scope" = l7 ] || [ "$scope" = forge ] || { echo 'usage: verify-istio-ambient.sh [control-plane|enrollment|l4|l7]' >&2; exit 1; }

kubectl --context "$MESH_CONTEXT" get crd gateways.gateway.networking.k8s.io >/dev/null
kubectl --context "$MESH_CONTEXT" -n istio-system rollout status deployment/istiod --timeout=180s
kubectl --context "$MESH_CONTEXT" -n istio-system rollout status daemonset/istio-cni-node --timeout=180s
kubectl --context "$MESH_CONTEXT" -n istio-system rollout status daemonset/ztunnel --timeout=180s
[ "$scope" = control-plane ] && exit 0

[ "$(kubectl --context "$MESH_CONTEXT" get namespace helixworks-forge -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')" = ambient ]
[ "$(kubectl --context "$MESH_CONTEXT" -n helixworks-forge get peerauthentication forge-strict-mtls -o jsonpath='{.spec.mtls.mode}')" = STRICT ]
for policy in control-plane-paths internal-services broker-publish-subscribe allow-ambient-kubelet-health-probes; do kubectl --context "$MESH_CONTEXT" -n helixworks-forge get networkpolicy "$policy" >/dev/null; done
[ "$scope" = enrollment ] && { echo 'Ambient enrollment, strict mTLS, HBONE, and health-probe policy are present.'; exit 0; }

kubectl --context "$MESH_CONTEXT" -n helixworks-forge get authorizationpolicy control-plane-l4-boundary generator-l4-boundary runtime-l4-boundary evidence-l4-boundary broker-l4-boundary >/dev/null
for policy in allow-bounded-bypass-observation-egress allow-bounded-bypass-observation-ingress; do kubectl --context "$MESH_CONTEXT" -n helixworks-forge get networkpolicy "$policy" >/dev/null; done
[ "$scope" = l4 ] && { verify_mesh_l4_policy; echo 'L4 identities and the allowed control-plane-to-generator path are proven; denial requires the bounded live probe.'; exit 0; }

[ "$(kubectl --context "$MESH_CONTEXT" get namespace helixworks-forge -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')" = forge-waypoint ]
kubectl --context "$MESH_CONTEXT" -n helixworks-forge wait gateway/forge-waypoint --for=condition=Accepted --timeout=180s
kubectl --context "$MESH_CONTEXT" -n helixworks-forge wait gateway/forge-waypoint --for=condition=Programmed --timeout=180s
kubectl --context "$MESH_CONTEXT" -n helixworks-forge rollout status deployment/forge-waypoint --timeout=180s
kubectl --context "$MESH_CONTEXT" -n helixworks-forge get authorizationpolicy generator-from-control-plane runtime-from-control-plane evidence-from-control-plane broker-from-publishers >/dev/null
for service_account in control-plane generator runtime evidence broker; do
  kubectl --context "$MESH_CONTEXT" -n helixworks-forge get serviceaccount "$service_account" >/dev/null
done
kubectl --context "$MESH_CONTEXT" -n helixworks-forge get networkpolicy forge-waypoint >/dev/null
verify_mesh_l7_policy
echo 'Waypoint and L7 POST/403 policy are proven. Live L4 denial and mTLS telemetry remain separate evidence gates.'
