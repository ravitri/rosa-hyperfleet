provider "aws" {
  region = var.region
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Shared GitHub CodeStar Connection
# The bootstrap script creates the connection (if needed) and waits for it to
# be authorized, then imports it here so terraform tracks it in state.
# During teardown, `terraform state rm` removes it before destroy so the
# connection persists across CI runs.
resource "aws_codestarconnections_connection" "github" {
  name          = "rosa-regional-github-shared"
  provider_type = "GitHub"
}

# Platform Image ECR Repository
module "platform_image" {
  source = "../../modules/platform-image"

  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  resource_name_base = "rosa-regional"
  name_prefix        = var.name_prefix
  tags = {
    Name        = "rosa-hyperfleet-image"
    Environment = var.environment
  }
}

module "codebuild_provisioner" {
  source = "../../modules/codebuild-provisioner"

  github_repository     = var.github_repository
  github_branch         = var.github_branch
  region                = var.region
  environment           = var.environment
  github_connection_arn = aws_codestarconnections_connection.github.arn
  platform_ecr_repo     = module.platform_image.ecr_repository_url
  name_prefix           = var.name_prefix
}

# CodeBuild Failure Notifications
# Gated by an explicit feature flag (see var.enable_slack_notifications).
# Currently only monitors the build-platform-image project.
# RC/MC notifications are SDK-side (out of scope for this module).
module "codebuild_notifications" {
  source = "../../modules/codebuild-notifications"
  count  = var.enable_slack_notifications ? 1 : 0

  slack_webhook_ssm_param = var.slack_webhook_ssm_param
  name_prefix             = var.name_prefix
  region                  = var.region
  project_names           = [module.codebuild_provisioner.build_platform_image_project_name]
}
