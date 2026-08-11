#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
environment="${1:?usage: verify-release.sh dev|staging|prod}"
manifest="$REPO_ROOT/gitops/apps/forge/overlays/$environment/kustomization.yaml"
if grep -q 'blocked-unpinned' "$manifest"; then echo "$environment deploy is blocked: no verified image digests" >&2; exit 1; fi
[ "$(grep -Ec 'digest: sha256:[0-9a-f]{64}$' "$manifest")" -eq 4 ]
grep -Eq 'newName: [0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/zheta-forge/' "$manifest"
grep -q 'ready-policies.yaml' "$manifest"
grep -q 'ready-capacity.yaml' "$manifest"
kubectl kustomize "$(dirname "$manifest")" >/dev/null
for contract in 'control-plane-secrets:SERVICE_TOKEN JWT_SECRET CONTROL_DATABASE_URL ARTIFACT_BUCKET' 'generator-secrets:SERVICE_TOKEN' 'runtime-secrets:SERVICE_TOKEN RUNTIME_DATABASE_URL' 'evidence-secrets:SERVICE_TOKEN EVIDENCE_DATABASE_URL'; do
  secret="${contract%%:*}"; keys="${contract#*:}"
  kubectl -n zheta-forge get secret "$secret" >/dev/null || { echo "blocked: durable $secret is absent" >&2; exit 1; }
  for key in $keys; do kubectl -n zheta-forge get secret "$secret" -o "jsonpath={.data.$key}" | grep -q . || { echo "blocked: $secret lacks $key" >&2; exit 1; }; done
done
echo "$environment release is digest-pinned and renderable."
