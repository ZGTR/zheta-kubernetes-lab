# Pinned local network substrate

Kind `v0.32.0` and its Kubernetes `1.35.5` node image bundle kindnet with the Kubernetes NetworkPolicy controller. Terraform pins the node image by digest; `scripts/verify-kind-network-policy.sh` rejects the wrong Kind binary, context, node image, or kindnet image and waits for every node-local agent.

Static pins do not prove packet enforcement. After deploying the local Forge overlay and before enrolling Ambient, run `scripts/probe-network-policy.sh`. It accepts only a timeout for the denied evidence-to-generator path, surrounds it with two allowed paths, and fails if kindnet or any reviewed workload identity is unavailable.
