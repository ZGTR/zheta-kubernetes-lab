# Zheta Forge architecture

Zheta Forge is not one generated web page. It is a bounded platform that turns an organization-owned blueprint into an immutable release while keeping provider administration, hosted runtime, and generated-application data independently authorized and revocable.

```mermaid
flowchart LR
  builder["Organization builder"] --> control["Forge control plane"]
  control --> generator["Deterministic generator"]
  generator --> runtime["Hosted runtime"]
  runtime --> user["Generated-app user"]
  control --> evidence["Immutable evidence"]
```

The smallest useful request path is builder to control plane to generator to runtime. Evidence is separate because an API response alone cannot prove who acted, against which organization, or which release was deployed.

## Complete customer lifecycle

| Step | Product action | Owning boundary | Durable evidence |
| --- | --- | --- | --- |
| Create | Create an organization-scoped blueprint | provider control plane | project identity and actor |
| Generate | Produce the same artifact for the same blueprint | generator, artifact store | content digest |
| Preview/interact | Deploy an unpublished artifact | hosted runtime | preview deployment identity |
| Managed data | Store generated-app tenant records | generated-application data plane | tenant-scoped data key |
| Connect | Grant a machine identity to one connector | provider control plane | independently revocable grant |
| Identify | Resolve organization actor and role | provider identity boundary | accepted or denied actor/scope |
| Share/revoke | Change collaborator access | provider control plane | grant or revocation event |
| Publish | Bind an immutable artifact to a release | hosted runtime | release and artifact IDs |
| Change/rollback | Deploy a new digest or restore an old release | hosted runtime | deployment/rollback event |
| Operate/support | Observe health, denial, and recovery | evidence service | timestamped evidence ID |
| Export/retire/delete | Return owned metadata, stop runtime, then erase control state | owning service at each boundary | export, retirement, deletion events |

Connector machine authority is taught first: an administrator grants a service identity such as `crm-reader`. A future delegated user grant would be a distinct record; it would not inherit the service grant or make the provider actor an end user inside a generated application.

## Responsibility and dependency direction

The control plane contains workflow policy and depends on small interfaces for generation, runtime deployment, and evidence. Concrete HTTP clients are injected at startup. This inversion of control keeps the domain testable without containers and prevents transport details from owning business rules.

- `control_plane`: organizations, projects, collaborators, connector grants, releases, lifecycle policy.
- `generator`: a deterministic source transformation; it cannot publish or grant access.
- `runtime`: preview and published deployment state; it cannot change provider membership.
- `evidence`: append-only observations; it cannot authorize the action it records.

For local learning these stores are intentionally in-memory, so process restart proves what is not production-ready. AWS replaces them with Aurora PostgreSQL, encrypted S3, and SQS while preserving the service ownership boundaries. Database adapters and workload identity are the next production implementation seam; no lesson should confuse the runnable analogue with durable production state.

## From declaration to physical reality

| Declaration | Interpreter | Software state | Hardware effect | Evidence |
| --- | --- | --- | --- | --- |
| `compose.yaml` | Docker Compose | five container processes and a private network | laptop CPU, RAM, disk, ports | health endpoints and lifecycle smoke output |
| Kustomize base + overlay | Kustomize and Kubernetes API | Deployments, Services, policies | containers scheduled onto Kind or EKS nodes | Ready pods, endpoints, rollout status |
| Argo CD ApplicationSet | ApplicationSet and application controllers | one Application per registered environment cluster | controllers use cluster network and CPU | Synced/Healthy plus Git revision |
| Terraform environment module | Terraform AWS provider | VPC, EKS, Aurora, S3, SQS, ECR, KMS | AWS network, compute, disk, and control-plane capacity | reviewed plan, resource IDs, Kubernetes nodes |

Decision rule: diagnose at the owner of the missing desired state. Terraform cannot repair a pod, Kubernetes cannot recreate a deleted VPC, and a healthy Argo Application cannot prove that an unreachable EKS API is healthy.
