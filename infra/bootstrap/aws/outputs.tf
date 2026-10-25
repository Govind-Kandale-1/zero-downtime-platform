output "state_bucket" {
  description = "Pass to every live root: terraform init -backend-config=bucket=<this>."
  value       = aws_s3_bucket.state.id
}

output "state_kms_key_arn" {
  value = aws_kms_key.state.arn
}

output "deploy_role_arn" {
  description = "Role for aws-actions/configure-aws-credentials (role-to-assume)."
  value       = aws_iam_role.deploy.arn
}
