# Environment promotion contract

Local, dev, staging, and production run the same four service responsibilities. They differ in substrate, isolation, durability, and release authority—not in business behavior.

| Layer | local | dev | staging | prod |
| --- | --- | --- | --- | --- |
| machine substrate | one laptop and Docker | dedicated AWS account and EKS | dedicated AWS account and EKS | dedicated AWS account and EKS |
| workload declaration | `overlays/local` | `overlays/dev` | `overlays/staging` | `overlays/prod` |
| images | locally loaded tag | immutable dev digest | digest proven in dev | approved digest proven in staging |
| managed state | intentionally volatile | isolated Aurora/S3/SQS | isolated Aurora/S3/SQS | protected Aurora/S3/SQS |
| authority | developer kubeconfig | dev deployment role | staging deployment role | production deployment role and approval |

Promotion changes only the overlay's immutable digests. It never copies credentials, Terraform state, database authority, or cluster tokens between accounts. Rollback selects a previously proven digest and leaves the immutable release record intact.

The local failure loop is: run the stack, complete a lifecycle, stop one service, observe the failed request, restart it, and rerun the request. In Kubernetes, delete one pod and watch the Deployment controller restore the replica. In Argo CD, mutate a live replica count and watch Git self-heal. In AWS, a node-group failure consumes separate availability-zone capacity while managed control planes and data services remain provider-operated; the product team still owns workload health and customer-visible recovery.
