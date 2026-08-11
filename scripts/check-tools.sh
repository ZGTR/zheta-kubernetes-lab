#!/usr/bin/env bash

source "$(dirname "$0")/lib.sh"

for tool in docker terraform kind kubectl; do
  require_command "$tool"
done
source "$REPO_ROOT/platform/kind/versions.env"
[ "$(kind version | awk '{print $2}')" = "$KIND_VERSION" ] || { echo "Kind $KIND_VERSION is required so the pinned kindnet NetworkPolicy engine is present." >&2; exit 1; }

if ! docker info >/dev/null 2>&1; then
  echo "Docker Desktop is installed but its engine is not ready." >&2
  echo "Start Docker Desktop, wait for Engine running, then retry." >&2
  exit 1
fi

mkdir -p "$REPO_ROOT/.kube" "$REPO_ROOT/.lab"
echo "Tooling and Docker engine are ready."
