#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
base_url="${FORGE_URL:-http://localhost:8080}"; actor_header="X-Actor: owner@acme.test"
post() { curl --fail --silent --show-error -H "$actor_header" -H 'Content-Type: application/json' -d "$2" "$base_url$1"; printf '\n'; }
post /projects '{"project_id":"support","organization_id":"acme","name":"Support operations"}'
post /projects/support/generate '{}'; post /projects/support/preview '{}'; post /projects/support/connectors '{"connector":"crm-reader"}'; post /projects/support/share '{"collaborator":"reviewer@acme.test"}'; post /projects/support/revoke '{"collaborator":"reviewer@acme.test"}'; post /projects/support/publish '{}'; post /projects/support/rollback '{"release_id":"rel-1"}'; post /projects/support/export '{}'; post /projects/support/retire '{}'
curl --fail --silent --show-error -X DELETE -H "$actor_header" "$base_url/projects/support"
printf '\nZheta Forge lifecycle completed with observable HTTP evidence.\n'
