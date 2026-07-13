provider "aws" {
  region = var.region

  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false

  dynamic "assume_role" {
    for_each = var.target_account_id != "" ? [1] : []
    content {
      role_arn     = "arn:aws:iam::${var.target_account_id}:role/OrganizationAccountAccessRole"
      session_name = "terraform-rhobs-${var.regional_id}"
    }
  }

  default_tags {
    tags = {
      app-code      = var.app_code
      service-phase = var.service_phase
      cost-center   = var.cost_center
      environment   = var.environment
    }
  }
}

# When PagerDuty is disabled, a dummy token lets the provider initialize
# without PAGERDUTY_TOKEN. When enabled, null falls through to the env var.
provider "pagerduty" {
  token                       = var.enable_pagerduty ? null : "not-configured"
  skip_credentials_validation = true
}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_caller_identity" "current" {}

# =============================================================================
# Remote State — RC VPC
#
# The RHOBS cluster runs in the same VPC as the Regional Cluster (architectural
# decision #1). We read the RC's VPC outputs via remote state to avoid
# duplicating VPC infrastructure.
# =============================================================================

data "terraform_remote_state" "regional_cluster" {
  backend = "s3"
  config = {
    bucket = var.rc_state_bucket
    key    = var.rc_state_key
    region = var.region
  }
}

locals {
  rc_vpc_id                          = data.terraform_remote_state.regional_cluster.outputs.vpc_id
  rc_vpc_cidr                        = data.terraform_remote_state.regional_cluster.outputs.vpc_cidr
  rc_private_subnet_ids              = data.terraform_remote_state.regional_cluster.outputs.private_subnets
  rc_cluster_security_group_id       = data.terraform_remote_state.regional_cluster.outputs.cluster_security_group_id
  rc_vpc_endpoints_security_group_id = data.terraform_remote_state.regional_cluster.outputs.vpc_endpoints_security_group_id
}

# =============================================================================
# External Secrets Operator — Pod Identity
#
# Grants ESO access to SSM Parameter Store and Secrets Manager so
# ClusterSecretStores can resolve regional secrets and config.
# =============================================================================

resource "aws_iam_role" "external_secrets_operator" {
  name        = "${var.regional_id}-rhobs-external-secrets-operator"
  description = "IAM role for External Secrets Operator on RHOBS cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = {
    Name      = "${var.regional_id}-rhobs-external-secrets-operator-role"
    ManagedBy = "terraform"
  }
}

resource "aws_iam_role_policy" "eso_ssm" {
  name = "${var.regional_id}-rhobs-eso-ssm"
  role = aws_iam_role.external_secrets_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ]
      Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.regional_id}/*"
    }]
  })
}

resource "aws_iam_role_policy" "eso_secretsmanager" {
  name = "${var.regional_id}-rhobs-eso-secretsmanager"
  role = aws_iam_role.external_secrets_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.regional_id}-*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "external_secrets_operator" {
  cluster_name    = module.rhobs_cluster.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets_operator.arn

  tags = {
    Name      = "${var.regional_id}-rhobs-external-secrets-operator-pod-identity"
    ManagedBy = "terraform"
  }
}

# =============================================================================
# EKS Cluster — RHOBS
#
# Dedicated EKS cluster for the observability stack. Runs in the same VPC as
# the RC but with its own node group, security groups, and IAM roles.
# =============================================================================

module "rhobs_cluster" {
  source = "../../modules/eks-cluster"

  cluster_type                    = "rhobs-cluster"
  cluster_id                      = "${var.regional_id}-rhobs"
  vpc_id                          = local.rc_vpc_id
  vpc_cidr                        = local.rc_vpc_cidr
  private_subnet_ids              = local.rc_private_subnet_ids
  cluster_security_group_id       = local.rc_cluster_security_group_id
  vpc_endpoints_security_group_id = local.rc_vpc_endpoints_security_group_id
}

# =============================================================================
# ECS Bootstrap — depends on EKS
# =============================================================================

module "ecs_bootstrap" {
  source = "../../modules/ecs-bootstrap"

  vpc_id                        = local.rc_vpc_id
  private_subnets               = local.rc_private_subnet_ids
  eks_cluster_arn               = module.rhobs_cluster.cluster_arn
  eks_cluster_name              = module.rhobs_cluster.cluster_name
  eks_cluster_security_group_id = local.rc_cluster_security_group_id
  cluster_id                    = "${var.regional_id}-rhobs"
  container_image               = var.container_image

  repository_url    = var.repository_url
  repository_branch = var.repository_branch

  thanos_kms_key_arn = module.thanos_infrastructure.kms_key_arn
  loki_kms_key_arn   = module.loki_infrastructure.kms_key_arn
}

# =============================================================================
# RHOBS API Gateway (Observability)
#
# Dedicated REST API + ALB for RHOBS traffic, fully isolated from the Platform
# API. Re-pointed from the RC to the RHOBS cluster's node security group.
# =============================================================================

module "rhobs_api_gateway" {
  source = "../../modules/rhobs-api-gateway"

  regional_id            = var.regional_id
  vpc_id                 = local.rc_vpc_id
  private_subnet_ids     = local.rc_private_subnet_ids
  node_security_group_id = module.rhobs_cluster.node_security_group_id
  cluster_name           = module.rhobs_cluster.cluster_name

  metrics_enabled = var.rhobs_apigw_metrics_enabled
}

# =============================================================================
# Thanos Infrastructure Module (Observability — Metrics)
#
# Uses var.regional_id (not the RHOBS cluster_id) as the S3 bucket prefix to
# preserve access to historical metrics data from the RC-hosted Thanos.
# =============================================================================

module "thanos_infrastructure" {
  source = "../../modules/thanos-infrastructure"

  cluster_id       = var.regional_id
  eks_cluster_name = module.rhobs_cluster.cluster_name

  metrics_retention_days = var.thanos_metrics_retention_days
  thanos_namespace       = var.thanos_namespace
  thanos_service_account = var.thanos_service_account
}

# =============================================================================
# Loki Infrastructure Module (Observability — Logs)
#
# Uses var.regional_id (not the RHOBS cluster_id) as the S3 bucket prefix to
# preserve access to historical log data from the RC-hosted Loki.
# =============================================================================

module "loki_infrastructure" {
  source = "../../modules/loki-infrastructure"

  cluster_id       = var.regional_id
  eks_cluster_name = module.rhobs_cluster.cluster_name

  logs_retention_days  = var.loki_logs_retention_days
  loki_namespace       = var.loki_namespace
  loki_service_account = var.loki_service_account
}

# =============================================================================
# CloudWatch Exporter (Pod Identity for YACE)
# =============================================================================

module "cloudwatch_exporter" {
  source       = "../../modules/cloudwatch-exporter"
  cluster_name = module.rhobs_cluster.cluster_name
}

# =============================================================================
# Grafana CloudWatch Logs (Pod Identity for CW Logs datasource)
# =============================================================================

module "grafana_cloudwatch_logs" {
  source       = "../../modules/grafana-cloudwatch-logs"
  mode         = "primary"
  cluster_name = module.rhobs_cluster.cluster_name
  regional_id  = var.regional_id
}

# =============================================================================
# PagerDuty Service (Optional)
# =============================================================================

module "pagerduty_service" {
  count  = var.enable_pagerduty ? 1 : 0
  source = "../../modules/pagerduty-service"

  regional_id          = var.regional_id
  environment          = var.environment
  region               = var.region
  eph_prefix           = var.eph_prefix
  escalation_policy_id = var.pagerduty_escalation_policy_id
}

# =============================================================================
# SNS Alerting Module (Phase 2 Alert Fan-Out)
# =============================================================================

module "sns_alerting" {
  count  = var.enable_sns_alerting ? 1 : 0
  source = "../../modules/sns-alerting"

  regional_id      = var.regional_id
  eks_cluster_name = module.rhobs_cluster.cluster_name
}
