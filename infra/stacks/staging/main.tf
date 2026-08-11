terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source = "hashicorp/aws", version = "= 5.100.0"
    }
  }
  backend "s3" {}
}
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
  assume_role {
    role_arn = var.deployer_role_arn
  }
  default_tags {
    tags = {
      Product = "zheta-forge", Environment = "staging"
    }
  }
}
module "environment" {
  source              = "../../modules/environment"
  environment         = "staging"
  expected_account_id = var.account_id
  deployer_role_arn   = var.deployer_role_arn
  monthly_budget_usd  = 700
  region              = var.region
  vpc_cidr            = "10.20.0.0/16"
  kubernetes_version  = var.kubernetes_version
  node_instance_types = ["m7i.large"]
  node_min_size       = 2
  node_max_size       = 8
  deletion_protection = false
}
