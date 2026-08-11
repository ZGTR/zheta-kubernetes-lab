#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_command kubectl
require_command ruby
terraform_bin="${TERRAFORM_BIN:-terraform}"
require_command "$terraform_bin"
terraform_version="$($terraform_bin version -json | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("terraform_version")')"
ruby -e 'exit Gem::Version.new(ARGV[0]) >= Gem::Version.new("1.10.0") ? 0 : 1' "$terraform_version" || { echo "Terraform >=1.10.0 required for locked S3 state and AWS validation; found $terraform_version" >&2; exit 1; }
python3 -m compileall -q "$REPO_ROOT/services"
python3 -m unittest discover -s "$REPO_ROOT/tests" -v
"$terraform_bin" -chdir="$REPO_ROOT/infra" fmt -check -recursive
for stack in dev staging prod; do
  test -f "$REPO_ROOT/infra/stacks/$stack/.terraform.lock.hcl"
  grep -q 'allowed_account_ids = \[var.account_id\]' "$REPO_ROOT/infra/stacks/$stack/main.tf"
  grep -q 'expected_account_id = var.account_id' "$REPO_ROOT/infra/stacks/$stack/main.tf"
  "$terraform_bin" -chdir="$REPO_ROOT/infra/stacks/$stack" init -backend=false -lockfile=readonly >/dev/null
  "$terraform_bin" -chdir="$REPO_ROOT/infra/stacks/$stack" validate
done
! rg -n 'registry\.example|sha256:(a{64}|b{64}|c{64})' "$REPO_ROOT/gitops/apps/forge/overlays"
grep -q 'replicas: 0' "$REPO_ROOT/gitops/apps/forge/base/workloads.yaml"
for environment in dev staging prod; do
  overlay="$REPO_ROOT/gitops/apps/forge/overlays/$environment/kustomization.yaml"
  if grep -q 'blocked-unpinned' "$overlay"; then
    ! grep -q 'digest:' "$overlay"
  else
    "$REPO_ROOT/scripts/verify-release.sh" "$environment"
  fi
done
for overlay in local dev staging prod; do kubectl kustomize "$REPO_ROOT/gitops/apps/forge/overlays/$overlay" >/dev/null; done
for manifest in "$REPO_ROOT/argocd/project.yaml" "$REPO_ROOT"/argocd/applicationsets/*.yaml; do
  ruby -e 'require "yaml"; YAML.load_stream(File.read(ARGV.fetch(0)))' "$manifest"
done
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then docker compose -f "$REPO_ROOT/compose.yaml" config >/dev/null; fi
echo "Service tests, four overlays, Argo CD YAML, and Compose contract passed."
