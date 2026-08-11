# Istio Ambient Mesh boundary

This directory pins the cluster-level prerequisites for the optional Zheta Forge ambient overlay. Istio `1.30.3` is the current patch release verified on 2026-08-11. Gateway API `v1.5.1` is the version required by the Istio 1.30 installation guide; the experimental CRD bundle is checksum-pinned before server-side apply.

The platform team owns `istio-base`, `istiod`, `istio-cni`, `ztunnel`, their upgrades, and cluster-scoped Gateway API resources. The Forge team owns namespace enrollment, its waypoint, destination policies, and application NetworkPolicies. Neither authority installs or launches the other implicitly.

The public repository is source only. No AWS or EKS installation is asserted. Read `docs/istio-ambient.md` before running the bounded scripts.
