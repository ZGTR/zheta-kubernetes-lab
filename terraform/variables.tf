variable "cluster_name" {
  description = "Name of the local Kind cluster and its Docker node containers."
  type        = string
  default     = "zheta-local"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.cluster_name))
    error_message = "cluster_name must contain lowercase letters, digits, and hyphens."
  }
}

variable "worker_count" {
  description = "Number of Docker-backed Kubernetes worker nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 4
    error_message = "worker_count must be between 1 and 4 for this laptop lab."
  }
}

variable "kind_node_image" {
  description = "Official Kind node image pin whose bundled kindnet enforces NetworkPolicy."
  type        = string
  default     = "kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95"

  validation {
    condition     = can(regex("^kindest/node:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[0-9a-f]{64}$", var.kind_node_image))
    error_message = "kind_node_image must be an immutable official Kind node digest."
  }
}
