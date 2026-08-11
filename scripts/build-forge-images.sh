#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_command docker
for service in control_plane generator runtime evidence broker; do
  image_name="helixworks-forge/${service//_/-}:v1"
  docker build --build-arg "SERVICE=$service" --tag "$image_name" --file "$REPO_ROOT/services/Dockerfile" "$REPO_ROOT"
  if kind get clusters | grep -qx "$CLUSTER_NAME"; then kind load docker-image "$image_name" --name "$CLUSTER_NAME"; fi
done
