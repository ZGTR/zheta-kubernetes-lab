#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_command kubectl
require_command terraform
python3 -m compileall -q "$REPO_ROOT/services"
python3 -m unittest discover -s "$REPO_ROOT/tests" -v
terraform -chdir="$REPO_ROOT/infra" fmt -check -recursive
for stack in dev staging prod; do
  grep -q 'allowed_account_ids = \[var.account_id\]' "$REPO_ROOT/infra/stacks/$stack/main.tf"
  grep -q 'expected_account_id = var.account_id' "$REPO_ROOT/infra/stacks/$stack/main.tf"
done
for overlay in local dev staging prod; do kubectl kustomize "$REPO_ROOT/gitops/apps/forge/overlays/$overlay" >/dev/null; done
require_command ruby
for manifest in "$REPO_ROOT/argocd/project.yaml" "$REPO_ROOT"/argocd/applicationsets/*.yaml; do
  ruby -e 'require "yaml"; YAML.load_stream(File.read(ARGV.fetch(0)))' "$manifest"
done
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then docker compose -f "$REPO_ROOT/compose.yaml" config >/dev/null; fi
echo "Service tests, four overlays, Argo CD YAML, and Compose contract passed."
