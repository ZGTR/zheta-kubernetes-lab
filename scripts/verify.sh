#!/usr/bin/env bash

source "$(dirname "$0")/lib.sh"

require_command terraform
require_command kubectl

terraform -chdir="$REPO_ROOT/terraform" fmt -check -recursive
terraform -chdir="$REPO_ROOT/terraform" init -backend=false
terraform -chdir="$REPO_ROOT/terraform" validate
kubectl kustomize "$REPO_ROOT/gitops/apps/zheta/base" >/dev/null
kubectl kustomize "$REPO_ROOT/gitops/apps/zheta/overlays/dev" >/dev/null

for script in "$REPO_ROOT"/scripts/*.sh; do
  bash -n "$script"
done

echo "Terraform, Kustomize, and shell validation passed."

