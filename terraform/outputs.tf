output "cluster_name" {
  description = "Kind cluster managed by Terraform."
  value       = kind_cluster.zheta.name
}

output "kubernetes_endpoint" {
  description = "Local Kubernetes API endpoint exposed by the control-plane container."
  value       = kind_cluster.zheta.endpoint
}

output "kubeconfig_path" {
  description = "Repository-local kubeconfig used by every lab command."
  value       = local.kubeconfig_path
}

