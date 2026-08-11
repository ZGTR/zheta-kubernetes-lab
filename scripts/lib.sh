#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-helixworks-local}"
export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/.kube/config}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cluster() {
  if [ ! -f "$KUBECONFIG" ]; then
    echo "Cluster kubeconfig not found. Run: make up" >&2
    exit 1
  fi
  kubectl cluster-info >/dev/null
}

