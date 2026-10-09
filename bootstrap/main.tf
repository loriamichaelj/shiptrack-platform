provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "shiptrack"
      Stack       = "platform"
      Environment = var.environment
      Owner       = var.owner
      CostCenter  = var.cost_center
      ManagedBy   = "terraform"
      Repo        = var.repositories.platform
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Created by hand (see README.md): an account can hold only one provider for this URL.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  account_id        = data.aws_caller_identity.current.account_id
  partition         = data.aws_partition.current.partition
  state_bucket_name = "shiptrack-tfstate-${local.account_id}-${var.aws_region}"
}

module "state" {
  source = "./state"

  bucket_name                = local.state_bucket_name
  account_id                 = local.account_id
  partition                  = local.partition
  noncurrent_expiration_days = var.state_noncurrent_expiration_days
}

module "policies" {
  source = "./policies"

  account_id        = local.account_id
  partition         = local.partition
  region            = var.aws_region
  github_org        = var.github_org
  repositories      = var.repositories
  environment       = var.environment
  role_prefix       = var.role_prefix
  branch            = var.branch
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  seed_role_name    = var.seed_role_name
  state_bucket_arn  = module.state.bucket_arn
  state_kms_key_arn = module.state.kms_key_arn
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "${var.role_prefix}-workload-boundary"
  description = "Permission boundary for every role created by the legacy and modern pipelines"
  policy      = module.policies.boundary_json
}

resource "aws_iam_role" "deploy" {
  for_each = module.policies.roles

  name                 = each.key
  description          = "Assumed by GitHub Actions through OIDC (${each.key})"
  assume_role_policy   = each.value.trust_json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "deploy" {
  for_each = module.policies.roles

  name   = "${each.key}-permissions"
  role   = aws_iam_role.deploy[each.key].id
  policy = each.value.inline_json
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = {
    for pair in flatten([
      for name, role in module.policies.roles : [
        for arn in role.managed_policy_arns : { key = "${name}|${arn}", role = name, arn = arn }
      ]
    ]) : pair.key => pair
  }

  role       = aws_iam_role.deploy[each.value.role].name
  policy_arn = each.value.arn
}
