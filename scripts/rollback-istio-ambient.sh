#!/usr/bin/env bash
source "$(dirname "$0")/istio-ambient-lib.sh"
require_mesh_context
require_mesh_approval MESH_ROLLBACK_APPROVED

namespace=zheta-forge
[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get configmap forge-environment -o jsonpath='{.data.ENVIRONMENT}')" = local ] || { echo 'mesh rollback veto: this bounded rollback supports only the local overlay' >&2; exit 1; }
[ "$(kubectl --context "$MESH_CONTEXT" get namespace "$namespace" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')" = ambient ] || { echo 'mesh rollback veto: namespace is not ambient' >&2; exit 1; }
[ "$(kubectl --context "$MESH_CONTEXT" get namespace "$namespace" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')" = forge-waypoint ] || { echo 'mesh rollback veto: namespace does not use forge-waypoint' >&2; exit 1; }
kubectl --context "$MESH_CONTEXT" -n "$namespace" get gateway forge-waypoint >/dev/null

kubectl --context "$MESH_CONTEXT" label namespace "$namespace" istio.io/use-waypoint- istio.io/dataplane-mode- --overwrite
kubectl --context "$MESH_CONTEXT" -n "$namespace" delete gateway forge-waypoint
kubectl --context "$MESH_CONTEXT" -n "$namespace" delete peerauthentication forge-strict-mtls
kubectl --context "$MESH_CONTEXT" -n "$namespace" delete authorizationpolicy control-plane-l4-boundary generator-l4-boundary runtime-l4-boundary evidence-l4-boundary broker-l4-boundary generator-from-control-plane runtime-from-control-plane evidence-from-control-plane broker-from-publishers
kubectl --context "$MESH_CONTEXT" -n "$namespace" delete networkpolicy forge-waypoint allow-ambient-kubelet-health-probes allow-bounded-bypass-observation-egress allow-bounded-bypass-observation-ingress
kubectl --context "$MESH_CONTEXT" apply -k "$REPO_ROOT/gitops/apps/forge/overlays/local"
kubectl --context "$MESH_CONTEXT" -n "$namespace" rollout status deployment --all --timeout=180s
kubectl --context "$MESH_CONTEXT" -n "$namespace" exec deployment/control-plane -- python -c 'import json,os,urllib.request; request=urllib.request.Request("http://generator:8080/generate", data=json.dumps({"name":"rollback-proof","archetype":"workflow"}).encode(), method="POST", headers={"Content-Type":"application/json","X-Service-Token":os.environ["SERVICE_TOKEN"]}); result=json.load(urllib.request.urlopen(request, timeout=5)); assert result["artifact_id"].startswith("sha256:")'
echo 'Forge was unenrolled and its base NetworkPolicies restored. Shared Istio releases and Gateway API CRDs were preserved.'
