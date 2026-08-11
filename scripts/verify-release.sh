#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
environment="${1:?usage: verify-release.sh dev|staging|prod}"
manifest="$REPO_ROOT/gitops/apps/forge/overlays/$environment/kustomization.yaml"
grep -qv 'blocked-unpinned' "$manifest"
[ "$(grep -Ec 'digest: sha256:[0-9a-f]{64}$' "$manifest")" -eq 4 ]
grep -Eq 'newName: [0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/zheta-forge/' "$manifest"
kubectl kustomize "$(dirname "$manifest")" >/dev/null
echo "$environment images are digest-pinned; this does not authorize launch."
