#!/usr/bin/env bash
source "$(dirname "$0")/istio-ambient-lib.sh"
require_mesh_context
require_mesh_approval MESH_FAILURE_APPROVED
mode="${1:?usage: failure-istio-ambient.sh ztunnel-recovery|waypoint-recovery}"
: "${TARGET_POD:?set TARGET_POD to the reviewed pod name}"
: "${TARGET_POD_UID:?set TARGET_POD_UID to the reviewed pod UID}"

positive_control() {
  kubectl --context "$MESH_CONTEXT" get --raw=/readyz >/dev/null
  [ "$(kubectl --context "$MESH_CONTEXT" -n helixworks-forge get deployment/control-plane -o jsonpath='{.status.availableReplicas}')" -ge 1 ]
}

validate_target() {
  namespace="$1"; label_path="$2"; expected_label="$3"; owner_kind="$4"
  actual_uid="$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$TARGET_POD" -o jsonpath='{.metadata.uid}')"
  [ "$actual_uid" = "$TARGET_POD_UID" ] || { echo 'mesh failure veto: target pod UID changed' >&2; exit 1; }
  actual_label="$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$TARGET_POD" -o "jsonpath=$label_path")"
  [ "$actual_label" = "$expected_label" ] || { echo "mesh failure veto: target label must equal $expected_label" >&2; exit 1; }
  actual_owner="$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$TARGET_POD" -o jsonpath='{.metadata.ownerReferences[0].kind}')"
  [ "$actual_owner" = "$owner_kind" ] || { echo "mesh failure veto: expected owner kind $owner_kind, found $actual_owner" >&2; exit 1; }
  target_owner_name="$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$TARGET_POD" -o jsonpath='{.metadata.ownerReferences[0].name}')"
}

positive_control
case "$mode" in
  ztunnel-recovery)
    validate_target istio-system '{.metadata.labels.app}' ztunnel DaemonSet
    target_node="$(kubectl --context "$MESH_CONTEXT" -n istio-system get pod "$TARGET_POD" -o jsonpath='{.spec.nodeName}')"
    kubectl --context "$MESH_CONTEXT" -n istio-system delete pod "$TARGET_POD" --wait=false
    positive_control
    kubectl --context "$MESH_CONTEXT" -n istio-system wait pod/"$TARGET_POD" --for=delete --timeout=120s
    kubectl --context "$MESH_CONTEXT" -n istio-system rollout status daemonset/ztunnel --timeout=180s
    replacement_json="$(kubectl --context "$MESH_CONTEXT" -n istio-system get pods -l app=ztunnel --field-selector "spec.nodeName=$target_node" -o json)"
    replacement_uid="$(python3 -c 'import json,sys; items=json.load(sys.stdin)["items"]; assert len(items)==1, f"expected one ztunnel replacement, got {len(items)}"; print(items[0]["metadata"]["uid"])' <<<"$replacement_json")"
    [ -n "$replacement_uid" ] && [ "$replacement_uid" != "$TARGET_POD_UID" ]
    ;;
  waypoint-recovery)
    validate_target helixworks-forge '{.metadata.labels.gateway\.networking\.k8s\.io/gateway-name}' forge-waypoint ReplicaSet
    [ "$(kubectl --context "$MESH_CONTEXT" -n helixworks-forge get replicaset "$target_owner_name" -o jsonpath='{.metadata.ownerReferences[0].name}')" = forge-waypoint ] || { echo 'mesh failure veto: waypoint ReplicaSet is not owned by forge-waypoint Deployment' >&2; exit 1; }
    [ "$(kubectl --context "$MESH_CONTEXT" -n helixworks-forge get pods -l gateway.networking.k8s.io/gateway-name=forge-waypoint -o jsonpath='{.items[*].metadata.uid}' | wc -w | tr -d ' ')" = 1 ] || { echo 'mesh failure veto: waypoint drill requires exactly one waypoint pod' >&2; exit 1; }
    kubectl --context "$MESH_CONTEXT" -n helixworks-forge delete pod "$TARGET_POD" --wait=false
    positive_control
    kubectl --context "$MESH_CONTEXT" -n helixworks-forge wait pod/"$TARGET_POD" --for=delete --timeout=120s
    kubectl --context "$MESH_CONTEXT" -n helixworks-forge rollout status deployment/forge-waypoint --timeout=180s
    replacement_json="$(kubectl --context "$MESH_CONTEXT" -n helixworks-forge get pods -l gateway.networking.k8s.io/gateway-name=forge-waypoint -o json)"
    replacement_uid="$(TARGET_OWNER="$target_owner_name" python3 -c 'import json,os,sys; items=json.load(sys.stdin)["items"]; assert len(items)==1, f"expected one waypoint replacement, got {len(items)}"; assert items[0]["metadata"]["ownerReferences"][0]["name"]==os.environ["TARGET_OWNER"]; print(items[0]["metadata"]["uid"])' <<<"$replacement_json")"
    [ -n "$replacement_uid" ] && [ "$replacement_uid" != "$TARGET_POD_UID" ]
    ;;
  *) echo 'usage: failure-istio-ambient.sh ztunnel-recovery|waypoint-recovery' >&2; exit 1 ;;
esac
positive_control
verify_mesh_product_policy
echo "$mode recovered an exact reviewed target while the API and product control remained healthy."
