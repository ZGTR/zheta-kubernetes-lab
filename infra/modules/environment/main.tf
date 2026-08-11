data "aws_availability_zones" "available" {
  state = "available"
}
data "aws_caller_identity" "current" {}

check "expected_account" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == var.expected_account_id
    error_message = "Authenticated AWS account does not match expected_account_id for ${var.environment}."
  }
}

locals {
  name = "zheta-forge-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
  tags = {
    Product = "zheta-forge", Environment = var.environment, ManagedBy = "terraform"
  }
}

resource "aws_kms_key" "data" {
  description             = "${local.name} envelope encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.tags
}
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${local.name}/cluster"
  retention_in_days = var.environment == "prod" ? 365 : 30
  kms_key_id        = aws_kms_key.data.arn
  tags              = local.tags
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = merge(local.tags, {
    Name = local.name
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = local.tags
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  map_public_ip_on_launch = true
  tags = merge(local.tags, {
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 8)
  tags = merge(local.tags, {
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"
  tags   = local.tags
}
resource "aws_nat_gateway" "this" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.this]
  tags          = local.tags
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = local.tags
}
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }
  tags = local.tags
}
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_security_group" "endpoints" {
  name   = "${local.name}-endpoints"
  vpc_id = aws_vpc.this.id
  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
  }
  tags = local.tags
}
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  tags              = local.tags
}
resource "aws_vpc_endpoint" "aws_services" {
  for_each            = toset(["ecr.api", "ecr.dkr", "kms", "sqs", "sts"])
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = local.tags
}
resource "aws_vpc_endpoint" "enterprise_connector" {
  for_each            = var.connector_service_names
  vpc_id              = aws_vpc.this.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = false
  tags                = merge(local.tags, { Connector = each.key })
}

resource "aws_iam_role" "cluster" {
  name = "${local.name}-cluster"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Effect = "Allow", Principal = {
        Service = "eks.amazonaws.com"
      }, Action = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}
resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}
resource "aws_eks_cluster" "this" {
  name                      = local.name
  role_arn                  = aws_iam_role.cluster.arn
  version                   = var.kubernetes_version
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = false
  }
  encryption_config {
    provider {
      key_arn = aws_kms_key.data.arn
    }
    resources = ["secrets"]
  }
  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }
  depends_on = [aws_iam_role_policy_attachment.cluster, aws_cloudwatch_log_group.eks]
  tags       = local.tags
}
resource "aws_eks_access_entry" "deployer" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.deployer_role_arn
  type          = "STANDARD"
}
resource "aws_eks_access_policy_association" "deployer" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.deployer_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.deployer]
}
resource "aws_iam_role" "nodes" {
  name = "${local.name}-nodes"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Effect = "Allow", Principal = {
        Service = "ec2.amazonaws.com"
      }, Action = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}
resource "aws_iam_role_policy_attachment" "nodes" {
  for_each   = toset(["arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy", "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly", "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"])
  role       = aws_iam_role.nodes.name
  policy_arn = each.value
}
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = var.node_instance_types
  scaling_config {
    desired_size = var.node_min_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }
  update_config {
    max_unavailable_percentage = 25
  }
  depends_on = [aws_iam_role_policy_attachment.nodes]
  tags       = local.tags
}
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_update = "PRESERVE"
  depends_on                  = [aws_eks_node_group.system]
  tags                        = local.tags
}

resource "aws_iam_role" "workload" {
  for_each = toset(["control-plane", "generator", "runtime", "evidence"])
  name     = "${local.name}-${each.value}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
  tags = local.tags
}
resource "aws_iam_role_policy" "workload" {
  for_each = aws_iam_role.workload
  name     = "bounded-platform-data"
  role     = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([{
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
      Resource = aws_kms_key.data.arn
      }, {
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = each.key == "runtime" ? aws_rds_cluster.application.master_user_secret[0].secret_arn : each.key == "evidence" ? aws_rds_cluster.evidence.master_user_secret[0].secret_arn : aws_rds_cluster.control.master_user_secret[0].secret_arn
    }], each.key == "control-plane" ? [{ Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = "${aws_s3_bucket.artifacts.arn}/control-plane/*" }, { Effect = "Allow", Action = ["sns:Publish"], Resource = aws_sns_topic.events.arn }] : [], each.key == "generator" ? [{ Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = "${aws_s3_bucket.artifacts.arn}/generator/*" }] : [], each.key == "runtime" ? [{ Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.artifacts.arn}/control-plane/*" }] : [], each.key == "evidence" ? [{ Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Resource = aws_sqs_queue.evidence.arn }] : [])
  })
}
resource "aws_eks_pod_identity_association" "workload" {
  for_each        = aws_iam_role.workload
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "zheta-forge"
  service_account = each.key
  role_arn        = each.value.arn
  depends_on      = [aws_eks_addon.pod_identity_agent]
}

resource "aws_ecr_repository" "services" {
  for_each             = toset(["control-plane", "generator", "runtime", "evidence"])
  name                 = "zheta-forge/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.data.arn
  }
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.tags
}
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.name}-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = false
  tags          = local.tags
}
resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
  }
}
resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_sns_topic" "events" {
  name                        = "${local.name}-events.fifo"
  fifo_topic                  = true
  content_based_deduplication = true
  kms_master_key_id           = aws_kms_key.data.id
  tags                        = local.tags
}
resource "aws_sqs_queue" "evidence" {
  name                        = "${local.name}-evidence.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  kms_master_key_id           = aws_kms_key.data.key_id
  tags                        = local.tags
}
resource "aws_sqs_queue" "operations" {
  name                        = "${local.name}-operations.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  kms_master_key_id           = aws_kms_key.data.key_id
  tags                        = local.tags
}
resource "aws_sns_topic_subscription" "events" {
  for_each             = { evidence = aws_sqs_queue.evidence.arn, operations = aws_sqs_queue.operations.arn }
  topic_arn            = aws_sns_topic.events.arn
  protocol             = "sqs"
  endpoint             = each.value
  raw_message_delivery = true
}
resource "aws_sqs_queue_policy" "events" {
  for_each  = { evidence = aws_sqs_queue.evidence, operations = aws_sqs_queue.operations }
  queue_url = each.value.id
  policy    = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "sns.amazonaws.com" }, Action = "sqs:SendMessage", Resource = each.value.arn, Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.events.arn } } }] })
}

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Product$zheta-forge"]
  }
}

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = aws_subnet.private[*].id
  tags       = local.tags
}
resource "aws_security_group" "database" {
  name   = "${local.name}-database"
  vpc_id = aws_vpc.this.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}
resource "aws_security_group_rule" "database_from_cluster" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.database.id
  source_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
resource "aws_rds_cluster" "control" {
  cluster_identifier                  = "${local.name}-control"
  engine                              = "aurora-postgresql"
  database_name                       = "forge"
  master_username                     = "forge_admin"
  manage_master_user_password         = true
  iam_database_authentication_enabled = true
  db_subnet_group_name                = aws_db_subnet_group.this.name
  vpc_security_group_ids              = [aws_security_group.database.id]
  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.data.arn
  backup_retention_period             = var.environment == "prod" ? 35 : 7
  deletion_protection                 = var.deletion_protection
  skip_final_snapshot                 = !var.deletion_protection
  final_snapshot_identifier           = var.deletion_protection ? "${local.name}-final" : null
  serverlessv2_scaling_configuration {
    min_capacity = var.environment == "prod" ? 1 : 0.5
    max_capacity = var.environment == "prod" ? 16 : 4
  }
  tags = local.tags
}
resource "aws_rds_cluster_instance" "control" {
  count              = var.environment == "prod" ? 2 : 1
  identifier         = "${local.name}-control-${count.index}"
  cluster_identifier = aws_rds_cluster.control.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.control.engine
  tags               = local.tags
}

resource "aws_rds_cluster" "application" {
  cluster_identifier                  = "${local.name}-application"
  engine                              = "aurora-postgresql"
  database_name                       = "generated_apps"
  master_username                     = "app_admin"
  manage_master_user_password         = true
  iam_database_authentication_enabled = true
  db_subnet_group_name                = aws_db_subnet_group.this.name
  vpc_security_group_ids              = [aws_security_group.database.id]
  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.data.arn
  backup_retention_period             = var.environment == "prod" ? 35 : 7
  deletion_protection                 = var.deletion_protection
  skip_final_snapshot                 = !var.deletion_protection
  final_snapshot_identifier           = var.deletion_protection ? "${local.name}-application-final" : null
  serverlessv2_scaling_configuration {
    min_capacity = var.environment == "prod" ? 1 : 0.5
    max_capacity = var.environment == "prod" ? 16 : 4
  }
  tags = local.tags
}
resource "aws_rds_cluster_instance" "application" {
  count              = var.environment == "prod" ? 2 : 1
  identifier         = "${local.name}-application-${count.index}"
  cluster_identifier = aws_rds_cluster.application.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.application.engine
  tags               = local.tags
}

resource "aws_rds_cluster" "evidence" {
  cluster_identifier                  = "${local.name}-evidence"
  engine                              = "aurora-postgresql"
  database_name                       = "evidence"
  master_username                     = "evidence_admin"
  manage_master_user_password         = true
  iam_database_authentication_enabled = true
  db_subnet_group_name                = aws_db_subnet_group.this.name
  vpc_security_group_ids              = [aws_security_group.database.id]
  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.data.arn
  backup_retention_period             = var.environment == "prod" ? 35 : 7
  deletion_protection                 = var.deletion_protection
  skip_final_snapshot                 = !var.deletion_protection
  final_snapshot_identifier           = var.deletion_protection ? "${local.name}-evidence-final" : null
  serverlessv2_scaling_configuration {
    min_capacity = var.environment == "prod" ? 1 : 0.5
    max_capacity = var.environment == "prod" ? 8 : 2
  }
  tags = local.tags
}
resource "aws_rds_cluster_instance" "evidence" {
  count              = var.environment == "prod" ? 2 : 1
  identifier         = "${local.name}-evidence-${count.index}"
  cluster_identifier = aws_rds_cluster.evidence.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.evidence.engine
  tags               = local.tags
}

resource "aws_backup_vault" "platform" {
  name        = local.name
  kms_key_arn = aws_kms_key.data.arn
  tags        = local.tags
}
resource "aws_iam_role" "backup" {
  name = "${local.name}-backup"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "backup.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = local.tags
}
resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}
resource "aws_iam_role_policy_attachment" "backup_s3" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Backup"
}
resource "aws_backup_plan" "platform" {
  name = local.name
  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.platform.name
    schedule          = "cron(0 3 * * ? *)"
    lifecycle {
      delete_after = var.environment == "prod" ? 35 : 7
    }
  }
  tags = local.tags
}
resource "aws_backup_selection" "platform" {
  name         = local.name
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.platform.id
  resources    = [aws_rds_cluster.control.arn, aws_rds_cluster.application.arn, aws_rds_cluster.evidence.arn, aws_s3_bucket.artifacts.arn]
}
