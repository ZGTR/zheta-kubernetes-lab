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

