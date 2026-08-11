#!/usr/bin/env bash

source "$(dirname "$0")/lib.sh"

require_command docker
require_command kind
require_cluster

docker build --tag zheta-demo:v1 "$REPO_ROOT/app"
kind load docker-image zheta-demo:v1 --name "$CLUSTER_NAME"

echo "Image zheta-demo:v1 is now stored inside every Kind node's container runtime."

