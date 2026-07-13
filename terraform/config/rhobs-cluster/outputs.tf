# =============================================================================
# RHOBS Cluster — EKS Outputs
# =============================================================================

output "cluster_name" {
  description = "RHOBS EKS cluster name"
  value       = module.rhobs_cluster.cluster_name
}

output "cluster_arn" {
  description = "RHOBS EKS cluster ARN"
  value       = module.rhobs_cluster.cluster_arn
}

output "cluster_endpoint" {
  description = "RHOBS EKS cluster API server endpoint"
  value       = module.rhobs_cluster.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for kubectl"
  value       = module.rhobs_cluster.cluster_certificate_authority_data
  sensitive   = true
}

output "node_security_group_id" {
  description = "RHOBS EKS node/pod security group ID (Auto Mode primary SG)"
  value       = module.rhobs_cluster.node_security_group_id
}

# =============================================================================
# ECS Bootstrap Outputs
# =============================================================================

output "ecs_cluster_arn" {
  description = "ECS cluster ARN for RHOBS bootstrap tasks"
  value       = module.ecs_bootstrap.ecs_cluster_arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name for RHOBS bootstrap tasks"
  value       = module.ecs_bootstrap.ecs_cluster_name
}

output "ecs_task_definition_arn" {
  description = "ECS task definition ARN for RHOBS bootstrap execution"
  value       = module.ecs_bootstrap.task_definition_arn
}

output "bootstrap_log_group_name" {
  description = "CloudWatch log group name for RHOBS bootstrap operations"
  value       = module.ecs_bootstrap.log_group_name
}

output "bootstrap_security_group_id" {
  description = "Security group ID for RHOBS bootstrap ECS tasks"
  value       = module.ecs_bootstrap.bootstrap_security_group_id
}

# =============================================================================
# ArgoCD Bootstrap Configuration Outputs
# =============================================================================

output "repository_url" {
  description = "Git repository URL for cluster configuration"
  value       = module.ecs_bootstrap.repository_url
}

output "repository_branch" {
  description = "Git branch for cluster configuration"
  value       = module.ecs_bootstrap.repository_branch
}

# =============================================================================
# RHOBS API Gateway Outputs
# =============================================================================

output "rhobs_api_url" {
  description = "RHOBS API Gateway invoke URL (used for MC/RC remote_write and Thanos Query)"
  value       = module.rhobs_api_gateway.invoke_url
}

output "thanos_target_group_arn" {
  description = "Target group ARN for Thanos Receive TargetGroupBinding (dedicated RHOBS ALB)"
  value       = module.rhobs_api_gateway.thanos_receive_target_group_arn
}

output "thanos_query_target_group_arn" {
  description = "Target group ARN for Thanos Query Frontend TargetGroupBinding (dedicated RHOBS ALB)"
  value       = module.rhobs_api_gateway.thanos_query_target_group_arn
}

output "loki_distributor_target_group_arn" {
  description = "Target group ARN for Loki Distributor TargetGroupBinding (dedicated RHOBS ALB)"
  value       = module.rhobs_api_gateway.loki_distributor_target_group_arn
}

output "loki_query_frontend_target_group_arn" {
  description = "Target group ARN for Loki Query Frontend TargetGroupBinding (dedicated RHOBS ALB)"
  value       = module.rhobs_api_gateway.loki_query_frontend_target_group_arn
}

# =============================================================================
# Thanos Infrastructure Outputs
# =============================================================================

output "thanos_helm_values" {
  description = "Helm values for Thanos Receiver chart (use with -f flag)"
  value       = module.thanos_infrastructure.helm_values
}

# =============================================================================
# Loki Infrastructure Outputs
# =============================================================================

output "loki_kms_key_arn" {
  description = "KMS key ARN for Loki S3 SSE-KMS encryption"
  value       = module.loki_infrastructure.kms_key_arn
}

# =============================================================================
# CloudWatch Exporter Outputs
# =============================================================================

output "cloudwatch_exporter_role_arn" {
  description = "IAM role ARN for CloudWatch Exporter (Pod Identity)"
  value       = module.cloudwatch_exporter.role_arn
}
