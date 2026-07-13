output "github_connection_arn" {
  description = "ARN of the GitHub CodeStar connection"
  value       = data.aws_codestarconnections_connection.github.arn
}

output "pipeline_name" {
  description = "Name of the CodePipeline"
  value       = aws_codepipeline.central_pipeline.name
}

output "pipeline_arn" {
  description = "ARN of the CodePipeline"
  value       = aws_codepipeline.central_pipeline.arn
}

output "codebuild_apply_name" {
  description = "Name of the apply CodeBuild project"
  value       = aws_codebuild_project.rhobs_apply.name
}

output "codebuild_bootstrap_name" {
  description = "Name of the bootstrap CodeBuild project"
  value       = aws_codebuild_project.rhobs_bootstrap.name
}

output "artifact_bucket" {
  description = "S3 bucket used for pipeline artifacts"
  value       = aws_s3_bucket.pipeline_artifact.id
}
