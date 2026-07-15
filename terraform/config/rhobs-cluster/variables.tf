# =============================================================================
# RHOBS Cluster Infrastructure Variables
# =============================================================================

variable "regional_id" {
  description = "Deterministic regional cluster identifier for resource naming. Reused from the RC to preserve S3 bucket naming for historical metrics/logs data."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.regional_id))
    error_message = "regional_id must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "environment" {
  description = "Environment name for tagging (e.g., 'integration', 'staging', 'production')"
  type        = string
}

variable "region" {
  description = "AWS Region for infrastructure deployment"
  type        = string
}

variable "container_image" {
  description = "Public ECR image URI for platform container (used by ECS bootstrap)"
  type        = string

  validation {
    condition     = length(var.container_image) > 0
    error_message = "container_image must be a non-empty ECR image URI"
  }
}

variable "target_account_id" {
  description = "Target AWS account ID for cross-account deployment. If empty, uses current account."
  type        = string
  default     = ""
}

variable "app_code" {
  description = "Application code for tagging (CMDB Application ID)"
  type        = string
}

variable "service_phase" {
  description = "Service phase for tagging (development, staging, or production)"
  type        = string
}

variable "cost_center" {
  description = "Cost center for tagging (3-digit cost center code)"
  type        = string
}

# =============================================================================
# Remote State — RC VPC Reference
# =============================================================================

variable "rc_state_bucket" {
  description = "S3 bucket name containing the Regional Cluster's Terraform state (for VPC outputs)"
  type        = string
}

variable "rc_state_key" {
  description = "S3 key for the Regional Cluster's Terraform state file"
  type        = string
}

# =============================================================================
# ArgoCD Bootstrap Configuration Variables
# =============================================================================

variable "repository_url" {
  description = "Git repository URL for cluster configuration"
  type        = string
}

variable "repository_branch" {
  description = "Git branch to use for cluster configuration"
  type        = string
  default     = "main"
}

# =============================================================================
# RHOBS API Gateway Variables
# =============================================================================

variable "rhobs_apigw_metrics_enabled" {
  description = "Enable detailed CloudWatch metrics for RHOBS API Gateway methods"
  type        = bool
  default     = true
}

# =============================================================================
# Thanos Configuration Variables
# =============================================================================

variable "thanos_metrics_retention_days" {
  description = "Number of days to retain metrics in S3 (FedRAMP minimum: 30 days)"
  type        = number
  default     = 365
}

variable "thanos_namespace" {
  description = "Kubernetes namespace where Thanos is deployed"
  type        = string
  default     = "thanos"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.thanos_namespace))
    error_message = "Namespace must conform to DNS-1123 label: lowercase alphanumeric and '-', starting and ending with alphanumeric, max 63 characters."
  }
}

variable "thanos_service_account" {
  description = "Kubernetes service account name for Thanos"
  type        = string
  default     = "thanos-operator"
}

# =============================================================================
# Loki Configuration Variables
# =============================================================================

variable "loki_logs_retention_days" {
  description = "Number of days to retain logs in S3 (FedRAMP minimum: 30 days)"
  type        = number
  default     = 90
}

variable "loki_namespace" {
  description = "Kubernetes namespace where Loki is deployed"
  type        = string
  default     = "loki"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.loki_namespace))
    error_message = "Namespace must conform to DNS-1123 label: lowercase alphanumeric and '-', starting and ending with alphanumeric, max 63 characters."
  }
}

variable "loki_service_account" {
  description = "Kubernetes service account name for Loki (shared by all Loki components in Distributed mode)"
  type        = string
  default     = "loki"
}

# =============================================================================
# Alerting Configuration Variables
# =============================================================================

variable "enable_sns_alerting" {
  description = "Enable SNS alerting for alert fan-out"
  type        = bool
  default     = false
}

variable "enable_pagerduty" {
  description = "Enable PagerDuty service provisioning for this region"
  type        = bool
  default     = false
}

variable "pagerduty_escalation_policy_id" {
  description = "ID of an existing PagerDuty escalation policy to use for the regional service"
  type        = string
  default     = ""
}

variable "eph_prefix" {
  description = "Ephemeral environment prefix (e.g., xg4y). Passed to PagerDuty service naming to avoid collisions."
  type        = string
  default     = ""
}

# =============================================================================
# Bastion Configuration
# =============================================================================

variable "enable_bastion" {
  description = "Enable ECS Fargate bastion for break-glass/development access to the cluster"
  type        = bool
  default     = false
}
