#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
environment="${1:?usage: verify-release.sh dev|staging|prod}"
manifest="$REPO_ROOT/gitops/apps/forge/overlays/$environment/kustomization.yaml"
! grep -q 'blocked-unpinned' "$manifest"
[ "$(grep -Ec 'digest: sha256:[0-9a-f]{64}$' "$manifest")" -eq 5 ]
[ "$(grep -Ec '^  - name: zheta-forge/(control-plane|generator|runtime|evidence|broker)$' "$manifest")" -eq 5 ]
for service in control-plane generator runtime evidence broker; do
  [ "$(grep -Ec "^    newName: [0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/zheta-forge/$service$" "$manifest")" -eq 1 ]
done
rendered="$(kubectl kustomize "$(dirname "$manifest")")"
for service in control-plane generator runtime evidence broker; do
  grep -Eq "image: [0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/zheta-forge/$service@sha256:[0-9a-f]{64}$" <<<"$rendered"
done
echo "$environment's five images are digest-pinned; this does not authorize launch."
