#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
environment="${1:?usage: launch-release.sh dev|staging|prod}"
[ "${PRIVATE_RUNNER:-0}" = 1 ] || { echo 'launch requires PRIVATE_RUNNER=1 inside the target private network' >&2; exit 1; }
require_command aws
require_command kubectl
: "${AWS_PROFILE:?launch requires an explicit AWS_PROFILE}"
: "${AWS_REGION:?launch requires an explicit AWS_REGION}"
: "${EXPECTED_AWS_ACCOUNT_ID:?launch requires EXPECTED_AWS_ACCOUNT_ID}"
[[ "$EXPECTED_AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo 'EXPECTED_AWS_ACCOUNT_ID must contain exactly 12 digits' >&2; exit 1; }
actual_account="$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)"
[ "$actual_account" = "$EXPECTED_AWS_ACCOUNT_ID" ] || { echo "launch veto: authenticated AWS account $actual_account does not equal $EXPECTED_AWS_ACCOUNT_ID" >&2; exit 1; }
"$REPO_ROOT/scripts/verify-release.sh" "$environment"
expected_cluster="zheta-forge-$environment"
context="forge-$environment"
aws eks update-kubeconfig --name "$expected_cluster" --region "$AWS_REGION" --profile "$AWS_PROFILE" --alias "$context"
actual_cluster="$(kubectl --context "$context" config view --minify -o jsonpath='{.contexts[0].context.cluster}')"
case "$actual_cluster" in *"$expected_cluster"*) ;; *) echo "connected cluster is not $expected_cluster" >&2; exit 1;; esac
manifest="$REPO_ROOT/gitops/apps/forge/overlays/$environment/kustomization.yaml"
kubectl --context "$context" -n zheta-forge get secret control-plane-secrets generator-secrets runtime-secrets evidence-secrets -o json \
  | python3 "$REPO_ROOT/scripts/validate-launch-contract.py" "$manifest" "$EXPECTED_AWS_ACCOUNT_ID" "$AWS_REGION"
python3 "$REPO_ROOT/scripts/launch-release.py" "$environment"
kubectl --context "$context" kustomize "$REPO_ROOT/gitops/apps/forge/overlays/$environment" >/dev/null
echo "Infrastructure launch contract passed. This does not run the authenticated product smoke or prove customer readiness. Review and commit the overlay change; this script does not push."
