#!/usr/bin/env bash

source "$(dirname "$0")/lib.sh"

require_command docker
require_cluster

mode="${1:-}"
worker_name="${CLUSTER_NAME}-worker"

validate_worker() {
  local actual_cluster
  local actual_role

  actual_cluster="$(docker inspect --format '{{index .Config.Labels "io.x-k8s.kind.cluster"}}' "$worker_name" 2>/dev/null || true)"
  actual_role="$(docker inspect --format '{{index .Config.Labels "io.x-k8s.kind.role"}}' "$worker_name" 2>/dev/null || true)"

  if [ "$actual_cluster" != "$CLUSTER_NAME" ] || [ "$actual_role" != "worker" ]; then
    echo "Refusing to touch $worker_name: expected a worker in Kind cluster $CLUSTER_NAME." >&2
    exit 1
  fi
}

case "$mode" in
  pod)
    pod_name="$(kubectl -n helixworks get pods -l app.kubernetes.io/name=helixworks -o jsonpath='{.items[0].metadata.name}')"
    if [ -z "$pod_name" ]; then
      echo "No HelixWorks pod found. Run: make deploy" >&2
      exit 1
    fi
    echo "Deleting pod $pod_name. The Deployment should create a replacement."
    kubectl -n helixworks delete pod "$pod_name"
    kubectl -n helixworks rollout status deployment/helixworks --timeout=120s
    kubectl -n helixworks get pods -o wide
    ;;
  node-down)
    validate_worker
    echo "Stopping Docker container $worker_name. This removes one simulated machine."
    docker stop "$worker_name"
    docker ps -a --filter "name=^/${worker_name}$" --format 'table {{.Names}}\t{{.Status}}'
    ;;
  node-up)
    validate_worker
    echo "Starting Docker container $worker_name. Its kubelet should rejoin the cluster."
    docker start "$worker_name"
    kubectl wait --for=condition=Ready "node/$worker_name" --timeout=180s
    kubectl get nodes
    ;;
  *)
    echo "Usage: $0 pod|node-down|node-up" >&2
    exit 1
    ;;
esac

