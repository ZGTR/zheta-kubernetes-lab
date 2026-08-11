#!/usr/bin/env bash

source "$(dirname "$0")/lib.sh"

require_cluster

ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.0}"
INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts -n argocd -f "$INSTALL_URL"
kubectl -n argocd wait --for=condition=Available deployment --all --timeout=300s
kubectl apply -f "$REPO_ROOT/argocd/application.yaml"

echo "Waiting for Argo CD to clone Git and reconcile the HelixWorks Application."
for attempt in $(seq 1 60); do
  sync_state="$(kubectl -n argocd get application helixworks -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health_state="$(kubectl -n argocd get application helixworks -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  printf 'attempt=%s sync=%s health=%s\n' "$attempt" "${sync_state:-Unknown}" "${health_state:-Unknown}"
  if [ "$sync_state" = "Synced" ] && [ "$health_state" = "Healthy" ]; then
    kubectl -n argocd get application helixworks
    exit 0
  fi
  sleep 5
done

echo "Argo CD did not reach Synced/Healthy within five minutes." >&2
kubectl -n argocd describe application helixworks >&2
exit 1

