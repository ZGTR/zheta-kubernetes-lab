variable "environment" {
  type = string
}
variable "expected_account_id" {
  type = string
}
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
