#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/istio-ambient-lib.sh"
require_mesh_context
require_mesh_approval MESH_BYPASS_PROBE_APPROVED

namespace=zheta-forge
: "${SOURCE_POD:?set SOURCE_POD to the reviewed evidence pod name}"
: "${SOURCE_POD_UID:?set SOURCE_POD_UID to the reviewed evidence pod UID}"
: "${TARGET_POD:?set TARGET_POD to the reviewed generator pod name}"
: "${TARGET_POD_UID:?set TARGET_POD_UID to the reviewed generator pod UID}"
: "${MESH_EVIDENCE_DIR:?set MESH_EVIDENCE_DIR to an existing absolute evidence directory}"
case "$MESH_EVIDENCE_DIR" in /*) ;; *) echo 'mesh probe veto: evidence directory must be absolute' >&2; exit 1 ;; esac
[ -d "$MESH_EVIDENCE_DIR" ] || { echo 'mesh probe veto: evidence directory does not exist' >&2; exit 1; }
for evidence_file in target.txt network-policy.yaml authorization-policy.yaml denial-stderr.txt ztunnel-observation.log controls.txt; do
  [ ! -e "$MESH_EVIDENCE_DIR/$evidence_file" ] || { echo "mesh probe veto: evidence file already exists: $evidence_file" >&2; exit 1; }
done

[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get configmap forge-environment -o jsonpath='{.data.ENVIRONMENT}')" = local ] || { echo 'mesh probe veto: bypass observation supports only the local overlay' >&2; exit 1; }
[ "$(kubectl --context "$MESH_CONTEXT" get namespace "$namespace" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')" = ambient ]
[ "$(kubectl --context "$MESH_CONTEXT" get namespace "$namespace" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')" = forge-waypoint ]
[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get authorizationpolicy allow-only-destination-waypoint -o jsonpath='{.spec.action}')" = ALLOW ]
[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get authorizationpolicy allow-only-destination-waypoint -o jsonpath='{.spec.rules[0].from[0].source.principals[0]}')" = cluster.local/ns/zheta-forge/sa/forge-waypoint ]

validate_workload() {
  pod="$1"; expected_uid="$2"; expected_app="$3"; expected_service_account="$4"
  [ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$pod" -o jsonpath='{.metadata.uid}')" = "$expected_uid" ] || { echo "mesh probe veto: $pod UID changed" >&2; exit 1; }
  [ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$pod" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}')" = "$expected_app" ]
  [ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$pod" -o jsonpath='{.spec.serviceAccountName}')" = "$expected_service_account" ]
  [ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]
  owner="$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$pod" -o jsonpath='{.metadata.ownerReferences[0].name}')"
  [ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$pod" -o jsonpath='{.metadata.ownerReferences[0].kind}')" = ReplicaSet ]
  [ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get replicaset "$owner" -o jsonpath='{.metadata.ownerReferences[0].name}')" = "$expected_app" ]
}

validate_workload "$SOURCE_POD" "$SOURCE_POD_UID" evidence evidence
validate_workload "$TARGET_POD" "$TARGET_POD_UID" generator generator
[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pods -l app.kubernetes.io/name=evidence -o jsonpath='{.items[*].metadata.uid}' | wc -w | tr -d ' ')" = 1 ]
[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pods -l app.kubernetes.io/name=generator -o jsonpath='{.items[*].metadata.uid}' | wc -w | tr -d ' ')" = 1 ]
target_ip="$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$TARGET_POD" -o jsonpath='{.status.podIP}')"
target_node="$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$TARGET_POD" -o jsonpath='{.spec.nodeName}')"
[ -n "$target_ip" ] && [ -n "$target_node" ]

ztunnel_json="$(kubectl --context "$MESH_CONTEXT" -n istio-system get pods -l app=ztunnel --field-selector "spec.nodeName=$target_node" -o json)"
read -r ztunnel_pod ztunnel_uid < <(python3 -c 'import json,sys; items=json.load(sys.stdin)["items"]; assert len(items)==1, f"expected one destination ztunnel, got {len(items)}"; assert any(c.get("type")=="Ready" and c.get("status")=="True" for c in items[0]["status"]["conditions"]); print(items[0]["metadata"]["name"], items[0]["metadata"]["uid"])' <<<"$ztunnel_json")

kubectl --context "$MESH_CONTEXT" -n "$namespace" get networkpolicy allow-bounded-bypass-observation -o yaml > "$MESH_EVIDENCE_DIR/network-policy.yaml"
grep -q 'app.kubernetes.io/name: evidence' "$MESH_EVIDENCE_DIR/network-policy.yaml"
grep -q 'app.kubernetes.io/name: generator' "$MESH_EVIDENCE_DIR/network-policy.yaml"
grep -q 'port: 8080' "$MESH_EVIDENCE_DIR/network-policy.yaml"
grep -q 'port: 15008' "$MESH_EVIDENCE_DIR/network-policy.yaml"
kubectl --context "$MESH_CONTEXT" -n "$namespace" get authorizationpolicy allow-only-destination-waypoint -o yaml > "$MESH_EVIDENCE_DIR/authorization-policy.yaml"
printf 'context=%s\nsource_pod=%s\nsource_uid=%s\nsource_identity=cluster.local/ns/zheta-forge/sa/evidence\ntarget_pod=%s\ntarget_uid=%s\ntarget_ip=%s\ntarget_node=%s\nztunnel_pod=%s\nztunnel_uid=%s\n' \
  "$MESH_CONTEXT" "$SOURCE_POD" "$SOURCE_POD_UID" "$TARGET_POD" "$TARGET_POD_UID" "$target_ip" "$target_node" "$ztunnel_pod" "$ztunnel_uid" > "$MESH_EVIDENCE_DIR/target.txt"

printf 'before: ' > "$MESH_EVIDENCE_DIR/controls.txt"
verify_mesh_product_policy >> "$MESH_EVIDENCE_DIR/controls.txt"
printf 'waypoint policy control passed\n' >> "$MESH_EVIDENCE_DIR/controls.txt"
probe_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if kubectl --context "$MESH_CONTEXT" -n "$namespace" exec pod/"$SOURCE_POD" -- \
  env TARGET_IP="$target_ip" python -c 'import os,socket,sys
s=socket.create_connection((os.environ["TARGET_IP"],8080),timeout=5)
s.sendall(b"GET / HTTP/1.1\r\nHost: direct-generator\r\nConnection: close\r\n\r\n")
data=s.recv(64)
sys.stderr.write(repr(data)+"\n")
raise SystemExit(0 if data else 18)' 2> "$MESH_EVIDENCE_DIR/denial-stderr.txt"; then
  echo 'mesh probe failed open: unauthorized direct destination returned application bytes' >&2
  exit 1
fi
kubectl --context "$MESH_CONTEXT" -n istio-system logs pod/"$ztunnel_pod" --since-time="$probe_started" > "$MESH_EVIDENCE_DIR/ztunnel-observation.log"
[ -s "$MESH_EVIDENCE_DIR/ztunnel-observation.log" ] || { echo 'mesh probe inconclusive: destination ztunnel emitted no observation' >&2; exit 1; }
[ "$(kubectl --context "$MESH_CONTEXT" -n istio-system get pod "$ztunnel_pod" -o jsonpath='{.metadata.uid}')" = "$ztunnel_uid" ]
[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$SOURCE_POD" -o jsonpath='{.metadata.uid}')" = "$SOURCE_POD_UID" ]
[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$TARGET_POD" -o jsonpath='{.metadata.uid}')" = "$TARGET_POD_UID" ]
printf 'after: ' >> "$MESH_EVIDENCE_DIR/controls.txt"
verify_mesh_product_policy >> "$MESH_EVIDENCE_DIR/controls.txt"
printf 'waypoint policy control passed\n' >> "$MESH_EVIDENCE_DIR/controls.txt"
echo "Direct evidence-to-generator Pod-IP transport was denied while NetworkPolicy admitted the path; review ztunnel observation: $MESH_EVIDENCE_DIR"
