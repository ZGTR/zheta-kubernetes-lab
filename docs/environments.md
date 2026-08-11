# Environment promotion contract

Local, dev, staging, and production run the same four service responsibilities. They differ in substrate, isolation, durability, and release authority—not in business behavior.

| Layer | local | dev | staging | prod |
| --- | --- | --- | --- | --- |
| machine substrate | one laptop and Docker | dedicated AWS account and EKS | dedicated AWS account and EKS | dedicated AWS account and EKS |
| workload declaration | `overlays/local` | `overlays/dev` | `overlays/staging` | `overlays/prod` |
| images | locally loaded tag | ECR digest pinned by PR | digest proven in dev | owner-approved staging digest |
| managed state | durable single-host SQLite | isolated Aurora/S3/SNS/SQS | isolated Aurora/S3/SNS/SQS | protected Aurora/S3/SNS/SQS |
| authority | developer kubeconfig | dev deployment role | staging deployment role | production deployment role and approval |

Image promotion changes only digest pins and leaves replicas at zero. It never copies credentials, Terraform state, database authority, or cluster tokens between accounts. Launch is a second change produced from inside the target private network after cluster identity and durable secret contracts pass. Rollback selects a previously proven digest; project deletion can still tombstone release metadata under the documented lifecycle policy.

KEDA, Karpenter, and metrics-server are not installed or referenced by a launchable overlay. Their controllers, CRDs, IAM, metrics, queue, AMI, and failure proofs are not complete. Launch therefore uses fixed replicas (two in dev/staging and three in production) within managed EKS node-group bounds. Public load balancing, DNS, TLS, and WAF are likewise absent and remain launch vetoes.

`scripts/launch-release.sh` is an infrastructure gate only. It requires an explicit AWS profile, region, expected 12-digit account, private runner, and named Kubernetes context. It does not replace the authenticated product smoke, database migration and restore dossier, image vulnerability scan, signature verification, or SBOM evidence.

The local failure loop is: run the stack, complete a lifecycle, stop one service, observe the failed request, restart it, and rerun the request. In Kubernetes, delete one pod and watch the Deployment controller restore the replica. In Argo CD, mutate a live replica count and watch Git self-heal. In AWS, a node-group failure consumes separate availability-zone capacity while managed control planes and data services remain provider-operated; the product team still owns workload health and customer-visible recovery.
