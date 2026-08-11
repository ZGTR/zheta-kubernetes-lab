variable "region" {
  type    = string
  default = "eu-west-2"
}
variable "account_id" {
  type = string
}
variable "deployer_role_arn" {
  type = string
}
variable "kubernetes_version" {
  type    = string
  default = "1.33"
}
