#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
base_url="${FORGE_URL:-http://localhost:8080}"
token="${FORGE_TOKEN:-$(python3 "$REPO_ROOT/scripts/mint-local-token.py")}"; auth_header="Authorization: Bearer $token"
post() { local extra=(); if [ -n "${3:-}" ]; then extra=(-H "Idempotency-Key: $3"); fi; curl --fail --silent --show-error -H "$auth_header" -H 'Content-Type: application/json' "${extra[@]}" -d "$2" "$base_url$1"; printf '\n'; }
post /projects '{"project_id":"support","organization_id":"acme","name":"Support operations","archetype":"workflow"}'
post /projects/support/generate '{}'
post /projects/support/preview '{}'
post /projects/support/connectors '{"connector":"crm-reader"}'
post /projects/support/share '{"collaborator":"reviewer@acme.test"}'
post /projects/support/revoke '{"collaborator":"reviewer@acme.test"}'
post /projects/support/publish '{}' smoke-publish-1
post /projects/support/rollback '{"release_id":"rel-1"}'
post /projects/support/export '{}'
post /projects/support/retire '{}'
curl --fail --silent --show-error -X DELETE -H "$auth_header" "$base_url/projects/support"
printf '\nZheta Forge lifecycle completed with authenticated, durable HTTP evidence.\n'
