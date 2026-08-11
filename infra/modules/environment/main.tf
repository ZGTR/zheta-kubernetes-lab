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
  name     = local.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version
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
  depends_on = [aws_iam_role_policy_attachment.cluster]
  tags       = local.tags
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
    Statement = [{
      Effect   = "Allow"
      Action   = each.key == "runtime" ? ["s3:GetObject"] : ["s3:GetObject", "s3:PutObject"]
      Resource = "${aws_s3_bucket.artifacts.arn}/${each.key}/*"
      }, {
      Effect   = "Allow"
      Action   = each.key == "generator" ? ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"] : ["sqs:SendMessage"]
      Resource = aws_sqs_queue.generation.arn
    }]
  })
}
resource "aws_eks_pod_identity_association" "workload" {
  for_each        = aws_iam_role.workload
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "zheta-forge"
  service_account = each.key
  role_arn        = each.value.arn
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
resource "aws_sqs_queue" "generation_dlq" {
  name                      = "${local.name}-generation-dlq"
  kms_master_key_id         = aws_kms_key.data.key_id
  message_retention_seconds = 1209600
  tags                      = local.tags
}
resource "aws_sqs_queue" "generation" {
  name              = "${local.name}-generation"
  kms_master_key_id = aws_kms_key.data.key_id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.generation_dlq.arn, maxReceiveCount = 5
  })
  tags = local.tags
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
  cluster_identifier          = "${local.name}-control"
  engine                      = "aurora-postgresql"
  database_name               = "forge"
  master_username             = "forge_admin"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [aws_security_group.database.id]
  storage_encrypted           = true
  kms_key_id                  = aws_kms_key.data.arn
  backup_retention_period     = var.environment == "prod" ? 35 : 7
  deletion_protection         = var.deletion_protection
  skip_final_snapshot         = !var.deletion_protection
  final_snapshot_identifier   = var.deletion_protection ? "${local.name}-final" : null
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
  cluster_identifier          = "${local.name}-application"
  engine                      = "aurora-postgresql"
  database_name               = "generated_apps"
  master_username             = "app_admin"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [aws_security_group.database.id]
  storage_encrypted           = true
  kms_key_id                  = aws_kms_key.data.arn
  backup_retention_period     = var.environment == "prod" ? 35 : 7
  deletion_protection         = var.deletion_protection
  skip_final_snapshot         = !var.deletion_protection
  final_snapshot_identifier   = var.deletion_protection ? "${local.name}-application-final" : null
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
