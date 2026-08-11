# AWS environment contract

Each environment is a separate AWS account, VPC, EKS cluster, database, queue, artifact bucket, encryption key, and container registry set. An identity or Kubernetes token in one account grants no authority in another. Run each stack only through its account-specific deployment role and state bucket.

| Environment | AWS account | CIDR | Nodes | Data protection | Promotion input |
| --- | --- | --- | --- | --- | --- |
| dev | dedicated non-production account | `10.10.0.0/16` | 2–6 | 7-day backup | immutable image digest from CI |
| staging | dedicated pre-production account | `10.20.0.0/16` | 2–8 | 7-day backup | digest proven in dev |
| prod | dedicated production account | `10.30.0.0/16` | 3–20 | deletion protection and 35-day backup | approved staging digest |

The account owner must first create the encrypted S3 state bucket named in `backend.hcl.example` and the deployment role. Terraform then interprets the stack, AWS creates network and compute capacity, EKS schedules workloads on EC2 nodes, and the evidence is the Terraform plan plus AWS and Kubernetes resource identities. No stack contains credentials or deploys automatically.

Every stack fails closed twice: the AWS provider permits only `account_id`, and the shared module compares the authenticated caller identity with the same expected account. EKS exposes a private API endpoint, two private subnets use separate availability-zone NAT gateways, and EKS Pod Identity binds each Kubernetes ServiceAccount to its own bounded AWS role. The control-plane and generated-application Aurora clusters are separate authority and deletion boundaries.

Production internet entry is intentionally a separately approved platform add-on: the AWS Load Balancer Controller, DNS record, ACM certificate, WAF policy, and certificate validation must be owned by the production networking stack before public traffic is enabled. These declarations do not expose an unauthenticated load balancer or invent a TLS secret. Private enterprise connectors are declared through `connector_service_names`: each approved ID creates a separate PrivateLink endpoint and still requires the application-level connector service grant; generic internet egress is not connector authority.

Daily AWS Backup selections cover both Aurora ownership planes and the artifact bucket. The output backup-plan ID, recovery-point inventory, retained final snapshots, and denied deletion while production protection is enabled are operational evidence; a successful Terraform apply alone is not proof that a restore works. A production readiness drill must restore into a disposable recovery environment and compare application records and artifact digests before enabling customer traffic.

```bash
terraform -chdir=infra/stacks/dev init -backend-config=backend.hcl
terraform -chdir=infra/stacks/dev plan -var='account_id=ACCOUNT_ID' -var='deployer_role_arn=DEPLOYER_ROLE_ARN'
```

Repeat with the staging and production directories only while authenticated to their explicit deployment roles. A plan is review evidence; an apply consumes billable AWS resources and requires owner approval.
