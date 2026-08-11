#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_command kubectl
require_cluster
"$REPO_ROOT/scripts/verify-kind-network-policy.sh" >/dev/null

[ "${NETWORK_POLICY_PROBE_APPROVED:-0}" = 1 ] || { echo 'NetworkPolicy probe veto: set NETWORK_POLICY_PROBE_APPROVED=1 after reviewing the local Pods' >&2; exit 1; }
: "${ALLOWED_SOURCE_POD:?set ALLOWED_SOURCE_POD to the reviewed control-plane pod}"
: "${ALLOWED_SOURCE_POD_UID:?set ALLOWED_SOURCE_POD_UID to its reviewed UID}"
: "${DENIED_SOURCE_POD:?set DENIED_SOURCE_POD to the reviewed evidence pod}"
: "${DENIED_SOURCE_POD_UID:?set DENIED_SOURCE_POD_UID to its reviewed UID}"
: "${DENIED_SOURCE_CONTROL_POD:?set DENIED_SOURCE_CONTROL_POD to the reviewed broker pod}"
: "${DENIED_SOURCE_CONTROL_POD_UID:?set DENIED_SOURCE_CONTROL_POD_UID to its reviewed UID}"
: "${TARGET_POD:?set TARGET_POD to the reviewed generator pod}"
: "${TARGET_POD_UID:?set TARGET_POD_UID to its reviewed UID}"
: "${NETWORK_POLICY_EVIDENCE_DIR:?set NETWORK_POLICY_EVIDENCE_DIR to an existing absolute directory}"
case "$NETWORK_POLICY_EVIDENCE_DIR" in /*) ;; *) echo 'NetworkPolicy probe veto: evidence directory must be absolute' >&2; exit 1 ;; esac
[ -d "$NETWORK_POLICY_EVIDENCE_DIR" ] || { echo 'NetworkPolicy probe veto: evidence directory does not exist' >&2; exit 1; }
for file in identities.txt network-policies.yaml positive-controls.txt negative-stderr.txt kindnet-status.txt; do
  [ ! -e "$NETWORK_POLICY_EVIDENCE_DIR/$file" ] || { echo "NetworkPolicy probe veto: evidence file exists: $file" >&2; exit 1; }
done

namespace=zheta-forge
[ "$(kubectl -n "$namespace" get configmap forge-environment -o jsonpath='{.data.ENVIRONMENT}')" = local ]
[ -z "$(kubectl get namespace "$namespace" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')" ] || { echo 'NetworkPolicy probe veto: namespace is already Ambient-enrolled' >&2; exit 1; }
[ -z "$(kubectl get namespace "$namespace" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')" ] || { echo 'NetworkPolicy probe veto: namespace already uses a waypoint' >&2; exit 1; }
for policy in default-deny control-plane-paths internal-services broker-publish-subscribe; do kubectl -n "$namespace" get networkpolicy "$policy" >/dev/null; done

validate_pod() {
  pod="$1"; uid="$2"; app="$3"; service_account="$4"
  [ "$(kubectl -n "$namespace" get pod "$pod" -o jsonpath='{.metadata.uid}')" = "$uid" ] || { echo "NetworkPolicy probe veto: $pod UID changed" >&2; exit 1; }
  [ "$(kubectl -n "$namespace" get pod "$pod" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}')" = "$app" ]
  [ "$(kubectl -n "$namespace" get pod "$pod" -o jsonpath='{.spec.serviceAccountName}')" = "$service_account" ]
  [ "$(kubectl -n "$namespace" get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]
  owner="$(kubectl -n "$namespace" get pod "$pod" -o jsonpath='{.metadata.ownerReferences[0].name}')"
  [ "$(kubectl -n "$namespace" get pod "$pod" -o jsonpath='{.metadata.ownerReferences[0].kind}')" = ReplicaSet ]
  [ "$(kubectl -n "$namespace" get replicaset "$owner" -o jsonpath='{.metadata.ownerReferences[0].name}')" = "$app" ]
  [ "$(kubectl -n "$namespace" get pods -l "app.kubernetes.io/name=$app" -o jsonpath='{.items[*].metadata.uid}' | wc -w | tr -d ' ')" = 1 ]
}
validate_pod "$ALLOWED_SOURCE_POD" "$ALLOWED_SOURCE_POD_UID" control-plane control-plane
validate_pod "$DENIED_SOURCE_POD" "$DENIED_SOURCE_POD_UID" evidence evidence
validate_pod "$DENIED_SOURCE_CONTROL_POD" "$DENIED_SOURCE_CONTROL_POD_UID" broker broker
validate_pod "$TARGET_POD" "$TARGET_POD_UID" generator generator
target_ip="$(kubectl -n "$namespace" get pod "$TARGET_POD" -o jsonpath='{.status.podIP}')"
broker_ip="$(kubectl -n "$namespace" get pod "$DENIED_SOURCE_CONTROL_POD" -o jsonpath='{.status.podIP}')"

kubectl -n kube-system get daemonset kindnet -o yaml > "$NETWORK_POLICY_EVIDENCE_DIR/kindnet-status.txt"
kubectl -n "$namespace" get networkpolicy default-deny control-plane-paths internal-services broker-publish-subscribe -o yaml > "$NETWORK_POLICY_EVIDENCE_DIR/network-policies.yaml"
printf 'allowed_source=%s\nallowed_source_uid=%s\nallowed_source_sa=control-plane\ndenied_source=%s\ndenied_source_uid=%s\ndenied_source_sa=evidence\ncontrol_target=%s\ncontrol_target_uid=%s\ncontrol_target_sa=broker\ntarget=%s\ntarget_uid=%s\ntarget_sa=generator\ntarget_ip=%s\n' \
  "$ALLOWED_SOURCE_POD" "$ALLOWED_SOURCE_POD_UID" "$DENIED_SOURCE_POD" "$DENIED_SOURCE_POD_UID" "$DENIED_SOURCE_CONTROL_POD" "$DENIED_SOURCE_CONTROL_POD_UID" "$TARGET_POD" "$TARGET_POD_UID" "$target_ip" > "$NETWORK_POLICY_EVIDENCE_DIR/identities.txt"

positive_controls() {
  kubectl -n "$namespace" exec pod/"$ALLOWED_SOURCE_POD" -- python -c 'import urllib.request; assert urllib.request.urlopen("http://generator:8080/healthz", timeout=5).status == 200'
  kubectl -n "$namespace" exec pod/"$DENIED_SOURCE_POD" -- env TARGET_IP="$broker_ip" python -c 'import os,urllib.request; assert urllib.request.urlopen("http://"+os.environ["TARGET_IP"]+":8080/healthz", timeout=5).status == 200'
}
positive_controls > "$NETWORK_POLICY_EVIDENCE_DIR/positive-controls.txt"
set +e
kubectl -n "$namespace" exec pod/"$DENIED_SOURCE_POD" -- env TARGET_IP="$target_ip" python -c 'import os,socket,sys
try:
 socket.create_connection((os.environ["TARGET_IP"],8080),timeout=3)
except TimeoutError as error:
 print(error,file=sys.stderr); raise SystemExit(42)
except Exception as error:
 print(error,file=sys.stderr); raise SystemExit(43)
raise SystemExit(0)' 2> "$NETWORK_POLICY_EVIDENCE_DIR/negative-stderr.txt"
negative_status=$?
set -e
[ "$negative_status" = 42 ] || { echo "NetworkPolicy probe inconclusive: expected enforced timeout status 42, got $negative_status" >&2; exit 1; }
positive_controls >> "$NETWORK_POLICY_EVIDENCE_DIR/positive-controls.txt"
validate_pod "$ALLOWED_SOURCE_POD" "$ALLOWED_SOURCE_POD_UID" control-plane control-plane
validate_pod "$DENIED_SOURCE_POD" "$DENIED_SOURCE_POD_UID" evidence evidence
validate_pod "$DENIED_SOURCE_CONTROL_POD" "$DENIED_SOURCE_CONTROL_POD_UID" broker broker
validate_pod "$TARGET_POD" "$TARGET_POD_UID" generator generator
echo "kindnet enforced the checked-in positive and negative paths; evidence: $NETWORK_POLICY_EVIDENCE_DIR"
