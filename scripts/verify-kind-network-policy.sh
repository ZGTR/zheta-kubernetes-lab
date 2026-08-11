#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_command kind
require_command kubectl
require_cluster
source "$REPO_ROOT/platform/kind/versions.env"

[ "$(kind version | awk '{print $2}')" = "$KIND_VERSION" ] || { echo "kindnet veto: Kind $KIND_VERSION is required" >&2; exit 1; }
[ "$(kubectl config current-context)" = "kind-$CLUSTER_NAME" ] || { echo 'kindnet veto: current context is not the exact Kind cluster' >&2; exit 1; }
kubectl -n kube-system rollout status daemonset/kindnet --timeout=180s
[ "$(kubectl -n kube-system get daemonset kindnet -o jsonpath='{.spec.template.spec.containers[*].image}')" = "$KINDNET_IMAGE" ] || { echo 'kindnet veto: unexpected node-local CNI image' >&2; exit 1; }
[ "$(kubectl -n kube-system get daemonset kindnet -o jsonpath='{.status.numberReady}')" = "$(kubectl get nodes --no-headers | wc -l | tr -d ' ')" ] || { echo 'kindnet veto: kindnet is not ready on every node' >&2; exit 1; }
kubectl wait nodes --all --for=condition=Ready --timeout=180s
echo "Kind $KIND_VERSION and $KINDNET_IMAGE are ready; live policy enforcement still requires the packet probe."
