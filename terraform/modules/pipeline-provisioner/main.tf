provider "aws" {
  region = var.region
  # FedRAMP SC-13 / IA-07: Use FIPS 140-2 validated endpoints when available.
  # FIPS endpoints exist only in US and GovCloud regions; non-US regions (EU, AP, SA)
  # do not support FIPS endpoints and will fail if this is set to true.
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # When name_prefix is set (e.g., "abc123"), names become "abc123-provisioner-artifacts", etc.
  name_prefix = var.name_prefix != "" ? "${var.name_prefix}-" : ""
}

# Use shared GitHub Connection (created in central-account-bootstrap)
data "aws_codestarconnections_connection" "github" {
  arn = var.github_connection_arn
}

# CodeBuild Project - Pipeline Provisioner
resource "aws_codebuild_project" "provisioner" {
  name                   = "${local.name_prefix}cluster-build-provisioner"
  service_role           = aws_iam_role.codebuild_role.arn
  build_timeout          = 60
  concurrent_build_limit = 1 # Prevent parallel executions (terraform lock)

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "GITHUB_REPOSITORY"
      value = var.github_repository
    }
    environment_variable {
      name  = "GITHUB_BRANCH"
      value = var.github_branch
    }
    environment_variable {
      name  = "ENVIRONMENT"
      value = var.environment
    }
    environment_variable {
      name  = "GITHUB_CONNECTION_ARN"
      value = data.aws_codestarconnections_connection.github.arn
    }
    environment_variable {
      name  = "PLATFORM_IMAGE"
      value = var.codebuild_image
    }
    environment_variable {
      name  = "MC_CODEBUILD_ROLE_ARN"
      value = var.mc_codebuild_role_arn
    }
  }

  source {
    type            = "GITHUB"
    location        = "https://github.com/${var.github_repository}.git"
    git_clone_depth = 0 # Full history for check-queue.sh git merge-base
    buildspec       = "terraform/modules/pipeline-provisioner/buildspec.yml"

    git_submodules_config {
      fetch_submodules = false
    }

    auth {
      type     = "CODECONNECTIONS"
      resource = data.aws_codestarconnections_connection.github.arn
    }
  }
}

# Webhook for provisioner project
resource "aws_codebuild_webhook" "provisioner" {
  project_name = aws_codebuild_project.provisioner.name
  build_type   = "BUILD"

  # Filter groups (ADR glob→regex; ENV/PUSH + HEAD_REF on all groups; groups OR-ed, filters AND-ed)
  # deploy/<env>/*/pipeline-provisioner-inputs/**
  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }
    filter {
      type    = "HEAD_REF"
      pattern = "^refs/heads/${var.github_branch}$"
    }
    filter {
      type    = "FILE_PATH"
      pattern = "^deploy/${var.environment}/[^/]+/pipeline-provisioner-inputs/.*"
    }
  }

  # terraform/config/pipeline-regional-cluster/**
  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }
    filter {
      type    = "HEAD_REF"
      pattern = "^refs/heads/${var.github_branch}$"
    }
    filter {
      type    = "FILE_PATH"
      pattern = "^terraform/config/pipeline-regional-cluster/.*"
    }
  }

  # terraform/config/pipeline-management-cluster/**
  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }
    filter {
      type    = "HEAD_REF"
      pattern = "^refs/heads/${var.github_branch}$"
    }
    filter {
      type    = "FILE_PATH"
      pattern = "^terraform/config/pipeline-management-cluster/.*"
    }
  }

  # terraform/modules/platform-image/**
  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }
    filter {
      type    = "HEAD_REF"
      pattern = "^refs/heads/${var.github_branch}$"
    }
    filter {
      type    = "FILE_PATH"
      pattern = "^terraform/modules/platform-image/.*"
    }
  }

  # scripts/build-platform-image.sh
  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }
    filter {
      type    = "HEAD_REF"
      pattern = "^refs/heads/${var.github_branch}$"
    }
    filter {
      type    = "FILE_PATH"
      pattern = "^scripts/build-platform-image\\.sh$"
    }
  }
}

# CodeBuild Project - Build Platform Image
resource "aws_codebuild_project" "build_platform_image" {
  name                   = "${local.name_prefix}build-platform-image"
  service_role           = aws_iam_role.build_platform_image_role.arn
  build_timeout          = 30
  concurrent_build_limit = 1 # Prevent parallel executions

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true # Required for docker build

    environment_variable {
      name  = "PLATFORM_ECR_REPO"
      value = var.platform_ecr_repo
    }
  }

  source {
    type            = "GITHUB"
    location        = "https://github.com/${var.github_repository}.git"
    git_clone_depth = 0 # Full history for check-queue.sh git merge-base
    buildspec       = "terraform/modules/pipeline-provisioner/buildspec-build-image.yml"

    git_submodules_config {
      fetch_submodules = false
    }

    auth {
      type     = "CODECONNECTIONS"
      resource = data.aws_codestarconnections_connection.github.arn
    }
  }
}

# Webhook for build-platform-image project
resource "aws_codebuild_webhook" "build_platform_image" {
  project_name = aws_codebuild_project.build_platform_image.name
  build_type   = "BUILD"

  # terraform/modules/platform-image/**
  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }
    filter {
      type    = "HEAD_REF"
      pattern = "^refs/heads/${var.github_branch}$"
    }
    filter {
      type    = "FILE_PATH"
      pattern = "^terraform/modules/platform-image/.*"
    }
  }

  # scripts/build-platform-image.sh
  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }
    filter {
      type    = "HEAD_REF"
      pattern = "^refs/heads/${var.github_branch}$"
    }
    filter {
      type    = "FILE_PATH"
      pattern = "^scripts/build-platform-image\\.sh$"
    }
  }
}

