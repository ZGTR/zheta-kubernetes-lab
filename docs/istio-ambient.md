# Istio Ambient Mesh for HelixWorks

This slice adds an optional, fail-closed service-mesh boundary to the existing monorepo. It does not add another product, repository, or business authority. The domain model, MVC controller, injected adapters, transactional outbox, and Pub/Sub contracts remain unchanged.

## What is pinned and what is proven

Istio `1.30.3` is pinned because it is the current patch release as of 2026-08-11. The official [1.30.3 release announcement](https://istio.io/latest/news/releases/1.30.x/announcing-1.30.3/) identifies it as the latest robustness patch. Istio's [production-oriented Ambient Helm guide](https://istio.io/latest/docs/ambient/install/helm/) requires Gateway API CRDs before a waypoint and currently uses Gateway API `v1.5.1`. `mesh/istio-ambient/versions.env` pins both versions and the downloaded CRD bundle's SHA-256.

Source rendering and static policy checks are proven locally. No Istio control plane, EKS cluster, AWS account, live mTLS session, denial, failover, or rollback was exercised by this commit. Kind v0.32.0, the Kubernetes 1.35.5 node digest, and its NetworkPolicy-enforcing kindnet image are pinned under `platform/kind`; these pins still require the checked-in live packet probe.

## Authority and traffic path

```mermaid
flowchart LR
  caller["Authenticated mesh caller SA"] --> source["Source ztunnel"]
  source --> waypoint["Destination forge-waypoint"]
  waypoint --> policy["Service targetRef L7 policy"]
  policy --> destination["Destination ztunnel"]
  destination --> service["Forge service SA"]
```

- The cluster platform owner installs Gateway API, `istio-base`, `istiod`, `istio-cni`, and `ztunnel`.
- The Forge owner enrolls only `helixworks-forge`, owns `forge-waypoint`, and attaches destination policies.
- Kubernetes ServiceAccounts remain the workload identity source. On EKS, the existing Pod Identity associations remain the separate AWS authorization source; SPIFFE identity does not grant AWS permissions.
- ztunnel enforces strict mTLS and the L4 source-principal rule. The waypoint enforces HTTP method/path rules attached with `targetRefs` to destination Services.
- NetworkPolicy remains CNI-owned defense in depth. Ambient does not bypass it.

The L4 policy deliberately accepts the waypoint identity at application workloads. This prevents direct waypoint bypass after all Forge sources are ambient. L7 policy still evaluates the original caller identity at the waypoint.

Customer ingress remains blocked in this slice. There is no ingress Gateway, public load balancer, DNS, certificate, WAF, or approved ingress ServiceAccount. Applying the ambient overlay before that authority exists makes the control-plane API reachable only through an enrolled destination waypoint path. This is an explicit launch veto, not an ingress implementation. Do not add an unauthenticated principal merely to make a smoke command pass.

## NetworkPolicy compatibility

Ambient uses HBONE TCP `15008`, so the component patches the existing application ingress policies to admit that overlay port. Istio's [Ambient NetworkPolicy guide](https://istio.io/latest/docs/ambient/usage/networkpolicy/) also requires allowing its health-probe SNAT sources. The component admits exactly `169.254.7.127/32` and `fd16:9254:7127:1337:ffff:ffff:ffff:ffff/128`; otherwise kubelet probes can fail after enrollment. The waypoint has its own bounded ingress/egress policy because Istio does not create NetworkPolicy for Gateway API-managed waypoints.

## Bounded local workflow

The default local/dev/staging/prod overlays remain unchanged. Before mesh enrollment, deploy the local product and prove the primary CNI's positive and negative paths with exact reviewed control-plane, evidence, broker, and generator Pod names and UIDs:

```bash
make cni-probe \
  NETWORK_POLICY_PROBE_APPROVED=1 \
  ALLOWED_SOURCE_POD=CONTROL_NAME ALLOWED_SOURCE_POD_UID=CONTROL_UID \
  DENIED_SOURCE_POD=EVIDENCE_NAME DENIED_SOURCE_POD_UID=EVIDENCE_UID \
  DENIED_SOURCE_CONTROL_POD=BROKER_NAME DENIED_SOURCE_CONTROL_POD_UID=BROKER_UID \
  TARGET_POD=GENERATOR_NAME TARGET_POD_UID=GENERATOR_UID \
  NETWORK_POLICY_EVIDENCE_DIR=/absolute/empty/evidence-directory
```

This probe fails if kindnet is not the pinned ready DaemonSet, any identity changed, an allowed path fails, or evidence-to-generator returns anything except the expected policy timeout. Static tests never count as this packet evidence.

The opt-in mesh progresses through three independently renderable overlays:

```bash
kubectl kustomize gitops/apps/forge/overlays/ambient-enrollment-local # Day 31: enrollment + STRICT mTLS
kubectl kustomize gitops/apps/forge/overlays/ambient-l4-local         # Day 32: destination L4 identities
kubectl kustomize gitops/apps/forge/overlays/ambient-local            # Day 33: waypoint + L7, full state
bash scripts/verify-ambient-source.sh
```

Installation mutates a cluster and therefore requires an exact current context and explicit approval:

```bash
MESH_CONTEXT=kind-helixworks-local MESH_INSTALL_APPROVED=1 bash scripts/install-istio-ambient.sh
kubectl --context kind-helixworks-local apply -k gitops/apps/forge/overlays/ambient-enrollment-local
MESH_CONTEXT=kind-helixworks-local bash scripts/verify-istio-ambient.sh enrollment
kubectl --context kind-helixworks-local apply -k gitops/apps/forge/overlays/ambient-l4-local
MESH_CONTEXT=kind-helixworks-local bash scripts/verify-istio-ambient.sh l4
kubectl --context kind-helixworks-local apply -k gitops/apps/forge/overlays/ambient-local
MESH_CONTEXT=kind-helixworks-local bash scripts/verify-istio-ambient.sh l7
```

Failure drills delete exactly one validated ztunnel or waypoint pod and wait for its controller:

```bash
kubectl --context kind-helixworks-local -n istio-system get pods -l app=ztunnel \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,NODE:.spec.nodeName
MESH_CONTEXT=kind-helixworks-local MESH_FAILURE_APPROVED=1 \
  TARGET_POD=REVIEWED_NAME TARGET_POD_UID=REVIEWED_UID \
  bash scripts/failure-istio-ambient.sh ztunnel-recovery
```

Use the same explicit name/UID process with the label `gateway.networking.k8s.io/gateway-name=forge-waypoint` for the waypoint drill. Each drill checks the Kubernetes API and an unaffected product Deployment before mutation, validates owner kind and UID, proves a different replacement UID, and executes an internal control-plane-to-generator request after recovery.

### Live probe, not static proof

`verify-ambient-source.sh` proves only that the L4/bypass probe is bounded and source controlled. It does not prove a live denial. At the Day 32 overlay, run `probe-istio-l4-authorization.sh`; it uses the allowed POST—not the Day 33 GET/403—as its positive control. After Day 33, `probe-istio-waypoint-bypass.sh` uses both the POST and the waypoint-enforced GET/403. Both require exact evidence, broker, and generator identities:

```bash
kubectl --context kind-helixworks-local -n helixworks-forge get pods \
  -l 'app.kubernetes.io/name in (broker,evidence,generator)' \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,IP:.status.podIP,NODE:.spec.nodeName
mkdir -p /tmp/helixworks-mesh-evidence
MESH_CONTEXT=kind-helixworks-local MESH_L4_PROBE_APPROVED=1 \
  SOURCE_POD=REVIEWED_EVIDENCE_NAME SOURCE_POD_UID=REVIEWED_EVIDENCE_UID \
  NETWORK_DENY_SOURCE_POD=REVIEWED_BROKER_NAME NETWORK_DENY_SOURCE_POD_UID=REVIEWED_BROKER_UID \
  TARGET_POD=REVIEWED_NAME TARGET_POD_UID=REVIEWED_UID \
  MESH_EVIDENCE_DIR=/tmp/helixworks-mesh-evidence \
  bash scripts/probe-istio-l4-authorization.sh
```

The paired NetworkPolicies select evidence egress and generator ingress explicitly and admit only ports `8080` and HBONE `15008`. Immediately before the mesh attempt, the probe requires a separate broker-to-generator connect timeout to prove kindnet is still enforcing the unexcepted path. The mesh attempt is deliberately different: it connects to the exact generator Pod IP, sends an HTTP request, and reads the response. Any HTTP response byte is a fail-open veto. Timeout, connection reset, broken pipe, connection abort, or EOF before any response byte is only a candidate transport denial; success additionally requires one destination-ztunnel record in the microsecond-bounded request window containing the target IP and port, evidence SPIFFE identity, and a denial indicator. Every other socket error is inconclusive. It mutates no cluster resources, and static verification does not claim this live evidence.

Rollback supports only the local overlay. It first proves the namespace is enrolled exactly as expected, removes enrollment and Forge-owned mesh resources, reapplies the local base NetworkPolicies, waits for every product Deployment, and proves an internal product request. Shared Istio releases and Gateway API CRDs are always preserved because they have a separate cluster owner.

## AWS and EKS mapping

The same Helm sequence can run from a private runner that reaches each private EKS API. Before any account is changed, the environment owner must separately prove:

1. exact AWS account, region, EKS context, and change approval;
2. the selected Kubernetes version is supported by Istio 1.30;
3. the EKS CNI/network-policy implementation admits HBONE and both health-probe addresses;
4. node kernel/CNI prerequisites, Pod Security admission, capacity, disruption budgets, and ztunnel-per-node recovery;
5. EKS Pod Identity associations remain scoped to the five existing application ServiceAccounts;
6. an approved ingress identity and destination-waypoint route exist before customer traffic;
7. live positive/negative L4 and L7 authorization evidence, mTLS telemetry, waypoint bypass denial, rollback, and cost evidence.

Nothing in Terraform or the cloud overlays installs Ambient Mesh. That separation prevents an unreviewed application promotion from gaining cluster-scoped mesh authority.
