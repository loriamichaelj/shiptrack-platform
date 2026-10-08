locals {
  inline_documents = {
    "shiptrack-platform-plan"  = data.aws_iam_policy_document.platform_plan.json
    "shiptrack-platform-apply" = data.aws_iam_policy_document.platform_apply.json
    "shiptrack-legacy-plan"    = data.aws_iam_policy_document.legacy_plan.json
    "shiptrack-legacy-apply"   = data.aws_iam_policy_document.legacy_apply.json
    "shiptrack-legacy-deploy"  = data.aws_iam_policy_document.legacy_deploy.json
    "shiptrack-modern-plan"    = data.aws_iam_policy_document.modern_plan.json
    "shiptrack-modern-apply"   = data.aws_iam_policy_document.modern_apply.json
    "shiptrack-modern-release" = data.aws_iam_policy_document.modern_release.json
    "shiptrack-modern-deploy"  = data.aws_iam_policy_document.modern_deploy.json
  }

  managed_policies = {
    "shiptrack-platform-plan"  = [local.managed.read_only]
    "shiptrack-platform-apply" = [local.managed.read_only, local.managed.power_user]
    "shiptrack-legacy-plan"    = [local.managed.read_only]
    "shiptrack-legacy-apply"   = [local.managed.read_only]
    "shiptrack-legacy-deploy"  = []
    "shiptrack-modern-plan"    = [local.managed.read_only]
    "shiptrack-modern-apply"   = [local.managed.read_only]
    "shiptrack-modern-release" = []
    "shiptrack-modern-deploy"  = []
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
