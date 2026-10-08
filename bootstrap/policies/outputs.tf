locals {
  inline_documents = {
    "${local.rp}-platform-plan"  = data.aws_iam_policy_document.platform_plan.json
    "${local.rp}-platform-apply" = data.aws_iam_policy_document.platform_apply.json
    "${local.rp}-legacy-plan"    = data.aws_iam_policy_document.legacy_plan.json
    "${local.rp}-legacy-apply"   = data.aws_iam_policy_document.legacy_apply.json
    "${local.rp}-legacy-deploy"  = data.aws_iam_policy_document.legacy_deploy.json
    "${local.rp}-modern-plan"    = data.aws_iam_policy_document.modern_plan.json
    "${local.rp}-modern-apply"   = data.aws_iam_policy_document.modern_apply.json
    "${local.rp}-modern-release" = data.aws_iam_policy_document.modern_release.json
    "${local.rp}-modern-deploy"  = data.aws_iam_policy_document.modern_deploy.json
  }

  managed_policies = {
    "${local.rp}-platform-plan"  = [local.managed.read_only]
    "${local.rp}-platform-apply" = [local.managed.read_only, local.managed.power_user]
    "${local.rp}-legacy-plan"    = [local.managed.read_only]
    "${local.rp}-legacy-apply"   = [local.managed.read_only]
    "${local.rp}-legacy-deploy"  = []
    "${local.rp}-modern-plan"    = [local.managed.read_only]
    "${local.rp}-modern-apply"   = [local.managed.read_only]
    "${local.rp}-modern-release" = []
    "${local.rp}-modern-deploy"  = []
  }
}

output "boundary_json" {
  description = "The workload permission boundary policy document."
  value       = data.aws_iam_policy_document.boundary.json
}

output "roles" {
  description = "Trust policy, inline policy, and managed policies for each deploy role."
  value = {
    for name in keys(local.role_subs) : name => {
      trust_json          = data.aws_iam_policy_document.trust[name].json
      inline_json         = local.inline_documents[name]
      managed_policy_arns = local.managed_policies[name]
    }
  }
}

output "boundary_arn" {
  description = "ARN the boundary policy will have."
  value       = local.boundary_arn
}
