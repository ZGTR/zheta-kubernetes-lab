#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
[ "${MESH_L4_PROBE_APPROVED:-0}" = 1 ] || { echo 'L4 probe veto: set MESH_L4_PROBE_APPROVED=1 after reviewing the exact Pods' >&2; exit 1; }
export MESH_BYPASS_PROBE_APPROVED=1
export MESH_PROBE_STAGE=l4
exec "$script_dir/probe-istio-waypoint-bypass.sh"
