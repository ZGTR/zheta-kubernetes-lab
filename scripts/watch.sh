#!/usr/bin/env bash

source "$(dirname "$0")/lib.sh"

require_command docker
require_cluster

render() {
  if [ "${WATCH_ONCE:-0}" != "1" ]; then
    printf '\033[2J\033[H'
  fi

  printf 'ZHETA LOCAL KUBERNETES LAB  %s\n' "$(date '+%H:%M:%S')"
  printf '%s\n' '============================================================'
  printf '\nDOCKER CONTAINERS THAT ACT AS KUBERNETES NODES\n'
  docker ps -a \
    --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" \
    --format 'table {{.Names}}\t{{.Status}}'

  printf '\nKUBERNETES NODES\n'
  kubectl get nodes -o wide

  printf '\nZHETA DESIRED AND ACTUAL POD STATE\n'
  kubectl -n zheta get deployment,pods -o wide 2>/dev/null || echo 'Zheta is not deployed yet. Run: make deploy'

  printf '\nRECENT EVENTS\n'
  kubectl -n zheta get events --sort-by=.lastTimestamp 2>/dev/null | tail -8 || true

  if kubectl api-resources --api-group=argoproj.io -o name 2>/dev/null | grep -q '^applications'; then
    printf '\nARGO CD GIT STATE\n'
    kubectl -n argocd get application zheta \
      -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' \
      2>/dev/null || echo 'Argo CD is installed; the Zheta Application is not created yet.'
  fi
}

if [ "${WATCH_ONCE:-0}" = "1" ]; then
  render
  exit 0
fi

while true; do
  render
  sleep 2
done

