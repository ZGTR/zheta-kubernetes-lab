output "cluster_name" {
  value = aws_eks_cluster.this.name
}
output "cluster_endpoint" {
  value     = aws_eks_cluster.this.endpoint
  sensitive = true
}
output "artifact_bucket" {
  value = aws_s3_bucket.artifacts.id
}
output "repository_urls" {
  value = {
    for name, repository in aws_ecr_repository.services : name => repository.repository_url
  }
}
output "generation_queue_url" {
  value = aws_sqs_queue.generation.url
}
output "control_database_endpoint" {
  value     = aws_rds_cluster.control.endpoint
  sensitive = true
}
output "application_database_endpoint" {
  value     = aws_rds_cluster.application.endpoint
  sensitive = true
}
