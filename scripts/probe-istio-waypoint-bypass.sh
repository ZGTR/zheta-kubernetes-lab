#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/istio-ambient-lib.sh"
require_mesh_context
require_mesh_approval MESH_BYPASS_PROBE_APPROVED
"$REPO_ROOT/scripts/verify-kind-network-policy.sh" >/dev/null
stage="${MESH_PROBE_STAGE:-l7}"
[ "$stage" = l4 ] || [ "$stage" = l7 ] || { echo 'mesh probe veto: MESH_PROBE_STAGE must be l4 or l7' >&2; exit 1; }

namespace=zheta-forge
: "${SOURCE_POD:?set SOURCE_POD to the reviewed evidence pod name}"
: "${SOURCE_POD_UID:?set SOURCE_POD_UID to the reviewed evidence pod UID}"
: "${TARGET_POD:?set TARGET_POD to the reviewed generator pod name}"
: "${TARGET_POD_UID:?set TARGET_POD_UID to the reviewed generator pod UID}"
: "${NETWORK_DENY_SOURCE_POD:?set NETWORK_DENY_SOURCE_POD to the reviewed broker pod name}"
: "${NETWORK_DENY_SOURCE_POD_UID:?set NETWORK_DENY_SOURCE_POD_UID to the reviewed broker pod UID}"
: "${MESH_EVIDENCE_DIR:?set MESH_EVIDENCE_DIR to an existing absolute evidence directory}"
case "$MESH_EVIDENCE_DIR" in /*) ;; *) echo 'mesh probe veto: evidence directory must be absolute' >&2; exit 1 ;; esac
[ -d "$MESH_EVIDENCE_DIR" ] || { echo 'mesh probe veto: evidence directory does not exist' >&2; exit 1; }
for evidence_file in target.txt network-policy.yaml authorization-policy.yaml denial-stderr.txt ztunnel-observation.log ztunnel-denial-record.log controls.txt; do
  [ ! -e "$MESH_EVIDENCE_DIR/$evidence_file" ] || { echo "mesh probe veto: evidence file already exists: $evidence_file" >&2; exit 1; }
done

[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get configmap forge-environment -o jsonpath='{.data.ENVIRONMENT}')" = local ] || { echo 'mesh probe veto: bypass observation supports only the local overlay' >&2; exit 1; }
[ "$(kubectl --context "$MESH_CONTEXT" get namespace "$namespace" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')" = ambient ]
if [ "$stage" = l4 ]; then
  [ -z "$(kubectl --context "$MESH_CONTEXT" get namespace "$namespace" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')" ] || { echo 'mesh probe veto: L4 stage must not use the Day 33 waypoint' >&2; exit 1; }
  expected_principal=cluster.local/ns/zheta-forge/sa/control-plane
else
  [ "$(kubectl --context "$MESH_CONTEXT" get namespace "$namespace" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')" = forge-waypoint ]
  expected_principal=cluster.local/ns/zheta-forge/sa/forge-waypoint
fi
[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get authorizationpolicy generator-l4-boundary -o jsonpath='{.spec.action}')" = ALLOW ]
[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get authorizationpolicy generator-l4-boundary -o jsonpath='{.spec.rules[0].from[0].source.principals[0]}')" = "$expected_principal" ]

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
validate_workload "$NETWORK_DENY_SOURCE_POD" "$NETWORK_DENY_SOURCE_POD_UID" broker broker
[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pods -l app.kubernetes.io/name=evidence -o jsonpath='{.items[*].metadata.uid}' | wc -w | tr -d ' ')" = 1 ]
[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pods -l app.kubernetes.io/name=generator -o jsonpath='{.items[*].metadata.uid}' | wc -w | tr -d ' ')" = 1 ]
target_ip="$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$TARGET_POD" -o jsonpath='{.status.podIP}')"
target_node="$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$TARGET_POD" -o jsonpath='{.spec.nodeName}')"
[ -n "$target_ip" ] && [ -n "$target_node" ]

ztunnel_json="$(kubectl --context "$MESH_CONTEXT" -n istio-system get pods -l app=ztunnel --field-selector "spec.nodeName=$target_node" -o json)"
read -r ztunnel_pod ztunnel_uid < <(python3 -c 'import json,sys; items=json.load(sys.stdin)["items"]; assert len(items)==1, f"expected one destination ztunnel, got {len(items)}"; assert any(c.get("type")=="Ready" and c.get("status")=="True" for c in items[0]["status"]["conditions"]); print(items[0]["metadata"]["name"], items[0]["metadata"]["uid"])' <<<"$ztunnel_json")

kubectl --context "$MESH_CONTEXT" -n "$namespace" get networkpolicy allow-bounded-bypass-observation-egress allow-bounded-bypass-observation-ingress -o yaml > "$MESH_EVIDENCE_DIR/network-policy.yaml"
grep -q 'app.kubernetes.io/name: evidence' "$MESH_EVIDENCE_DIR/network-policy.yaml"
grep -q 'app.kubernetes.io/name: generator' "$MESH_EVIDENCE_DIR/network-policy.yaml"
grep -q 'port: 8080' "$MESH_EVIDENCE_DIR/network-policy.yaml"
grep -q 'port: 15008' "$MESH_EVIDENCE_DIR/network-policy.yaml"
[ "$(grep -c 'app.kubernetes.io/name: evidence' "$MESH_EVIDENCE_DIR/network-policy.yaml")" -ge 2 ]
[ "$(grep -c 'app.kubernetes.io/name: generator' "$MESH_EVIDENCE_DIR/network-policy.yaml")" -ge 2 ]
kubectl --context "$MESH_CONTEXT" -n "$namespace" get authorizationpolicy generator-l4-boundary -o yaml > "$MESH_EVIDENCE_DIR/authorization-policy.yaml"
printf 'context=%s\nsource_pod=%s\nsource_uid=%s\nsource_identity=cluster.local/ns/zheta-forge/sa/evidence\nnetwork_deny_source=%s\nnetwork_deny_source_uid=%s\ntarget_pod=%s\ntarget_uid=%s\ntarget_ip=%s\ntarget_node=%s\nztunnel_pod=%s\nztunnel_uid=%s\n' \
  "$MESH_CONTEXT" "$SOURCE_POD" "$SOURCE_POD_UID" "$NETWORK_DENY_SOURCE_POD" "$NETWORK_DENY_SOURCE_POD_UID" "$TARGET_POD" "$TARGET_POD_UID" "$target_ip" "$target_node" "$ztunnel_pod" "$ztunnel_uid" > "$MESH_EVIDENCE_DIR/target.txt"

printf 'before: ' > "$MESH_EVIDENCE_DIR/controls.txt"
if [ "$stage" = l4 ]; then verify_mesh_l4_policy >> "$MESH_EVIDENCE_DIR/controls.txt"; else verify_mesh_l7_policy >> "$MESH_EVIDENCE_DIR/controls.txt"; fi
printf '%s policy control passed\n' "$stage" >> "$MESH_EVIDENCE_DIR/controls.txt"

# This independent path has no egress exception. Accept only the timeout that
# demonstrates the primary CNI is enforcing policy immediately before the mesh probe.
set +e
kubectl --context "$MESH_CONTEXT" -n "$namespace" exec pod/"$NETWORK_DENY_SOURCE_POD" -- env TARGET_IP="$target_ip" python -c 'import os,socket,sys
try:
 socket.create_connection((os.environ["TARGET_IP"],8080),timeout=3)
except TimeoutError as error:
 print(error,file=sys.stderr); raise SystemExit(42)
except Exception as error:
 print(error,file=sys.stderr); raise SystemExit(43)
raise SystemExit(0)' >> "$MESH_EVIDENCE_DIR/controls.txt" 2>&1
network_denial_status=$?
set -e
[ "$network_denial_status" = 42 ] || { echo "mesh probe veto: NetworkPolicy enforcement status was $network_denial_status, expected 42" >&2; exit 1; }

probe_started="$(python3 -c 'from datetime import datetime,timezone; print(datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00","Z"))')"
set +e
kubectl --context "$MESH_CONTEXT" -n "$namespace" exec pod/"$SOURCE_POD" -- env TARGET_IP="$target_ip" python -c 'import os,socket,sys
try:
 socket.create_connection((os.environ["TARGET_IP"],8080),timeout=3)
except TimeoutError as error:
 print(error,file=sys.stderr); raise SystemExit(42)
except Exception as error:
 print(error,file=sys.stderr); raise SystemExit(43)
raise SystemExit(0)' 2> "$MESH_EVIDENCE_DIR/denial-stderr.txt"
mesh_denial_status=$?
set -e
[ "$mesh_denial_status" = 42 ] || { echo "mesh probe inconclusive: expected Istio transport denial status 42, got $mesh_denial_status" >&2; exit 1; }

correlated=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kubectl --context "$MESH_CONTEXT" -n istio-system logs pod/"$ztunnel_pod" --since-time="$probe_started" > "$MESH_EVIDENCE_DIR/ztunnel-observation.log"
  if TARGET_IP="$target_ip" python3 -c 'import os,re,sys
target=os.environ["TARGET_IP"]+":8080"
identity="spiffe://cluster.local/ns/zheta-forge/sa/evidence"
denial=re.compile(r"denied|authorization|policy rejection|rbac", re.IGNORECASE)
matches=[line for line in open(sys.argv[1], encoding="utf-8") if target in line and identity in line and denial.search(line)]
if not matches: raise SystemExit(1)
sys.stdout.write(matches[-1])' "$MESH_EVIDENCE_DIR/ztunnel-observation.log" > "$MESH_EVIDENCE_DIR/ztunnel-denial-record.log"; then
    correlated=1
    break
  fi
  sleep 2
done
[ "$correlated" = 1 ] || { echo 'mesh probe inconclusive: no single target-IP:port/source-identity/policy-denial record in the exact ztunnel window' >&2; exit 1; }
[ "$(kubectl --context "$MESH_CONTEXT" -n istio-system get pod "$ztunnel_pod" -o jsonpath='{.metadata.uid}')" = "$ztunnel_uid" ]
[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$SOURCE_POD" -o jsonpath='{.metadata.uid}')" = "$SOURCE_POD_UID" ]
[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$TARGET_POD" -o jsonpath='{.metadata.uid}')" = "$TARGET_POD_UID" ]
[ "$(kubectl --context "$MESH_CONTEXT" -n "$namespace" get pod "$NETWORK_DENY_SOURCE_POD" -o jsonpath='{.metadata.uid}')" = "$NETWORK_DENY_SOURCE_POD_UID" ]
printf 'after: ' >> "$MESH_EVIDENCE_DIR/controls.txt"
if [ "$stage" = l4 ]; then verify_mesh_l4_policy >> "$MESH_EVIDENCE_DIR/controls.txt"; else verify_mesh_l7_policy >> "$MESH_EVIDENCE_DIR/controls.txt"; fi
printf '%s policy control passed\n' "$stage" >> "$MESH_EVIDENCE_DIR/controls.txt"
echo "Direct evidence-to-generator Pod-IP transport was denied at the $stage boundary while NetworkPolicy admitted the path; evidence: $MESH_EVIDENCE_DIR"
