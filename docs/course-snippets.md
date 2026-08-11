# Course snippet index

This public repository is the executable monorepo for both the Kubernetes foundations course and the Zheta Forge AWS/GitOps course. Course prose should link to these stable files rather than copy drifting alternatives.

| Concept | Stable source |
| --- | --- |
| Local process topology | `compose.yaml` |
| Container build contract | `services/Dockerfile` |
| MVC Model and SRP ports | `services/control_plane/domain.py` |
| MVC Controller | `services/control_plane/controller.py` |
| MVC View and IoC composition root | `services/control_plane/app.py` |
| Durable DI adapters | `services/control_plane/adapters.py` and `services/shared/persistence.py` |
| Authenticated tenant boundary | `services/shared/auth.py` |
| Transactional outbox relay | `services/control_plane/outbox.py` |
| Local and AWS Pub/Sub adapters | `services/shared/broker.py` |
| Idempotent durable Pub/Sub subscriber | `services/evidence/app.py` and `services/shared/persistence.py` |
| Three generated application archetypes and XSS boundary | `services/generator/app.py` |
| Service-to-service authentication | `services/generator/app.py`, `services/runtime/app.py`, `services/evidence/app.py` |
| Kubernetes workload base | `gitops/apps/forge/base/workloads.yaml` |
| Local Kustomize overlay | `gitops/apps/forge/overlays/local/kustomization.yaml` |
| Blocked cloud overlay before promotion | `gitops/apps/forge/overlays/prod/kustomization.yaml` |
| Five-image digest pinning, including broker, and disabled supply-chain candidate | `scripts/promote-release.py` and `.github/workflows/promote-forge.yaml` |
| Private launch gate | `scripts/launch-release.sh` and `scripts/launch-release.py` |
| Optional Ambient Mesh boundary | `gitops/apps/forge/mesh/ambient`, `scripts/install-istio-ambient.sh`, and `docs/istio-ambient.md` |
| In-cluster Argo CD per private EKS cluster | `argocd/applicationsets/forge-dev.yaml`, `forge-staging.yaml`, `forge-prod.yaml` |
| Original local Kind IaC | `terraform/main.tf` |
| Reusable AWS IaC module | `infra/modules/environment/main.tf` |
| Isolated production account stack | `infra/stacks/prod/main.tf` |
| Restart, concurrency, recoverable publish, tenancy, tombstone, fan-out, archetype and XSS proofs | `tests/test_domain.py` |

The architecture rule is consistent across both courses: Terraform owns substrate, Kubernetes owns workload replicas, Argo CD owns Git-rendered cluster state, and the services own tenant-scoped product records. None of those authorities inherits another.
