#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_command kubectl
require_command ruby

source "$REPO_ROOT/mesh/istio-ambient/versions.env"
[ "$ISTIO_VERSION" = 1.30.3 ]
[ "$GATEWAY_API_VERSION" = v1.5.1 ]
[[ "$GATEWAY_API_SHA256" =~ ^[0-9a-f]{64}$ ]]

manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
kubectl kustomize "$REPO_ROOT/gitops/apps/forge/overlays/ambient-local" > "$manifest"
ruby -e 'require "yaml"; documents=YAML.load_stream(File.read(ARGV.fetch(0))); abort "empty ambient render" if documents.empty?' "$manifest"

grep -q 'gatewayClassName: istio-waypoint' "$manifest"
grep -q 'protocol: HBONE' "$manifest"
grep -q 'istio.io/dataplane-mode: ambient' "$manifest"
grep -q 'istio.io/use-waypoint: forge-waypoint' "$manifest"
[ "$(grep -c 'apiVersion: security.istio.io/v1$' "$manifest")" -eq 6 ]
grep -q 'mode: STRICT' "$manifest"
grep -q 'cluster.local/ns/zheta-forge/sa/forge-waypoint' "$manifest"
grep -q 'port: 15008' "$manifest"
grep -q 'cidr: 169.254.7.127/32' "$manifest"
grep -q 'cidr: fd16:9254:7127:1337:ffff:ffff:ffff:ffff/128' "$manifest"

for identity in control-plane generator runtime evidence broker; do
  grep -q "serviceAccountName: $identity" "$manifest"
done
! grep -A20 'name: allow-only-destination-waypoint' "$manifest" | grep -Eq 'methods:|paths:'
grep -A20 'name: generator-from-control-plane' "$manifest" | grep -q 'targetRefs:'
for environment in dev staging prod; do
  ! grep -q 'mesh/ambient' "$REPO_ROOT/gitops/apps/forge/overlays/$environment/kustomization.yaml"
done
for script in install-istio-ambient.sh verify-istio-ambient.sh failure-istio-ambient.sh rollback-istio-ambient.sh; do
  bash -n "$REPO_ROOT/scripts/$script"
done
grep -q 'MESH_INSTALL_APPROVED' "$REPO_ROOT/scripts/install-istio-ambient.sh"
grep -q 'MESH_FAILURE_APPROVED' "$REPO_ROOT/scripts/failure-istio-ambient.sh"
grep -q 'MESH_ROLLBACK_APPROVED' "$REPO_ROOT/scripts/rollback-istio-ambient.sh"
grep -q 'TARGET_POD_UID' "$REPO_ROOT/scripts/failure-istio-ambient.sh"
! grep -q 'helm uninstall' "$REPO_ROOT/scripts/rollback-istio-ambient.sh"
! grep -q '|| true' "$REPO_ROOT/scripts/rollback-istio-ambient.sh"
echo 'Ambient source contracts render and fail-closed operational scripts are bounded.'
