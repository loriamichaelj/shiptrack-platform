# Outputs hold account IDs, so they are marked sensitive and never printed by the workflow.
# Read them with `aws iam get-role` or the console when wiring the repositories (README.md).

output "state_bucket_name" {
  value     = module.state.bucket_name
  sensitive = true
}

output "state_kms_key_arn" {
  value     = module.state.kms_key_arn
  sensitive = true
}

output "permission_boundary_arn" {
  value     = aws_iam_policy.workload_boundary.arn
  sensitive = true
}

output "role_arns" {
  value     = { for name, role in aws_iam_role.deploy : name => role.arn }
  sensitive = true
}
