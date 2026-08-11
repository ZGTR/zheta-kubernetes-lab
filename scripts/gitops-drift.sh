#!/usr/bin/env bash

source "$(dirname "$0")/lib.sh"

require_cluster

if ! kubectl -n argocd get application zheta >/dev/null 2>&1; then
  echo "Argo CD Application not found. Run: make argocd-up" >&2
  exit 1
fi

echo "Creating live drift: scaling Zheta from Git's 3 replicas down to 1."
kubectl -n zheta scale deployment/zheta --replicas=1
kubectl -n zheta get deployment zheta

echo "Waiting for Argo CD self-heal to restore the Git value of 3."
for attempt in $(seq 1 60); do
  replicas="$(kubectl -n zheta get deployment zheta -o jsonpath='{.spec.replicas}')"
  sync_state="$(kubectl -n argocd get application zheta -o jsonpath='{.status.sync.status}')"
  printf 'attempt=%s replicas=%s sync=%s\n' "$attempt" "$replicas" "$sync_state"
  if [ "$replicas" = "3" ] && [ "$sync_state" = "Synced" ]; then
    kubectl -n zheta get deployment,pods
    exit 0
  fi
  sleep 2
done

echo "Argo CD did not repair the drift within two minutes." >&2
exit 1

