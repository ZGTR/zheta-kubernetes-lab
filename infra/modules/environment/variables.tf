variable "environment" {
  type = string
}
variable "expected_account_id" {
  type = string
}
variable "deployer_role_arn" { type = string }
variable "monthly_budget_usd" { type = number }
variable "region" {
  type = string
}
variable "vpc_cidr" {
  type = string
}
variable "kubernetes_version" {
  type = string
}
variable "node_instance_types" {
  type = list(string)
}
variable "node_min_size" {
  type = number
}
variable "node_max_size" {
  type = number
}
variable "deletion_protection" {
  type = bool
}
variable "connector_service_names" {
  description = "Approved AWS PrivateLink service names keyed by connector ID. Empty means no private enterprise connector is authorized."
  type        = map(string)
  default     = {}
}
