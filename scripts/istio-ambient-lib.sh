#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO_ROOT/mesh/istio-ambient/versions.env"

require_mesh_context() {
  require_command kubectl
  : "${MESH_CONTEXT:?set MESH_CONTEXT to the exact kubectl context}"
  current="$(kubectl config current-context)"
  [ "$current" = "$MESH_CONTEXT" ] || { echo "mesh veto: current context $current does not equal $MESH_CONTEXT" >&2; exit 1; }
  kubectl --context "$MESH_CONTEXT" cluster-info >/dev/null
}

require_mesh_approval() {
  variable="$1"
  [ "${!variable:-0}" = 1 ] || { echo "mesh veto: set $variable=1 after reviewing the target context" >&2; exit 1; }
}

verify_mesh_product_policy() {
  kubectl --context "$MESH_CONTEXT" -n zheta-forge exec deployment/control-plane -- python -c 'import json,os,urllib.request; request=urllib.request.Request("http://generator:8080/generate", data=json.dumps({"name":"mesh-policy-proof","archetype":"workflow"}).encode(), method="POST", headers={"Content-Type":"application/json","X-Service-Token":os.environ["SERVICE_TOKEN"]}); result=json.load(urllib.request.urlopen(request, timeout=5)); assert result["artifact_id"].startswith("sha256:")'
  kubectl --context "$MESH_CONTEXT" -n zheta-forge exec deployment/control-plane -- python -c 'import urllib.error,urllib.request
try:
 urllib.request.urlopen("http://generator:8080/generate", timeout=5)
 raise SystemExit("mesh policy failed open: GET /generate succeeded")
except urllib.error.HTTPError as error:
 assert error.code == 403, error.code'
}
