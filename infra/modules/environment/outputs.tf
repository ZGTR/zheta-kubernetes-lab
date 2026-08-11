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
output "event_topic_arn" { value = aws_sns_topic.events.arn }
output "evidence_queue_url" { value = aws_sqs_queue.evidence.url }
output "operations_queue_url" { value = aws_sqs_queue.operations.url }
output "control_database_endpoint" {
  value     = aws_rds_cluster.control.endpoint
  sensitive = true
}
output "application_database_endpoint" {
  value     = aws_rds_cluster.application.endpoint
  sensitive = true
}
output "evidence_database_endpoint" {
  value     = aws_rds_cluster.evidence.endpoint
  sensitive = true
}
output "backup_plan_id" {
  value = aws_backup_plan.platform.id
}
output "connector_endpoint_ids" {
  value = { for name, endpoint in aws_vpc_endpoint.enterprise_connector : name => endpoint.id }
}
