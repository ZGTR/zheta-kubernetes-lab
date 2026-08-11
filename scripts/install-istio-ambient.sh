#!/usr/bin/env bash
source "$(dirname "$0")/istio-ambient-lib.sh"
require_mesh_context
require_mesh_approval MESH_INSTALL_APPROVED
require_command helm
require_command curl

bundle="$(mktemp)"
trap 'rm -f "$bundle"' EXIT
curl -fsSL "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/experimental-install.yaml" -o "$bundle"
if command -v sha256sum >/dev/null 2>&1; then actual_sha="$(sha256sum "$bundle" | awk '{print $1}')"; else actual_sha="$(shasum -a 256 "$bundle" | awk '{print $1}')"; fi
[ "$actual_sha" = "$GATEWAY_API_SHA256" ] || { echo 'mesh veto: Gateway API checksum mismatch' >&2; exit 1; }
kubectl --context "$MESH_CONTEXT" apply --server-side -f "$bundle"

helm repo add istio https://istio-release.storage.googleapis.com/charts --force-update
helm repo update istio
helm upgrade --install istio-base istio/base --kube-context "$MESH_CONTEXT" --version "$ISTIO_VERSION" -n istio-system --create-namespace --wait --set global.networkPolicy.enabled=true
helm upgrade --install istiod istio/istiod --kube-context "$MESH_CONTEXT" --version "$ISTIO_VERSION" -n istio-system --wait --set profile=ambient --set global.networkPolicy.enabled=true
helm upgrade --install istio-cni istio/cni --kube-context "$MESH_CONTEXT" --version "$ISTIO_VERSION" -n istio-system --wait --set profile=ambient --set global.networkPolicy.enabled=true
helm upgrade --install ztunnel istio/ztunnel --kube-context "$MESH_CONTEXT" --version "$ISTIO_VERSION" -n istio-system --wait --set global.networkPolicy.enabled=true

"$REPO_ROOT/scripts/verify-istio-ambient.sh" control-plane
echo "Istio Ambient $ISTIO_VERSION installed; Forge remains unenrolled until its ambient overlay is applied."
