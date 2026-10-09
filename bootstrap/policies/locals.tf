locals {
  p   = var.partition
  a   = var.account_id
  r   = var.region
  env = var.environment
  rp  = var.role_prefix

  boundary_arn  = "arn:${local.p}:iam::${local.a}:policy/${var.role_prefix}-workload-boundary"
  seed_role_arn = "arn:${local.p}:iam::${local.a}:role/${var.seed_role_name}"

  stacks = ["platform", "legacy", "modern"]
  # Repositories issue tokens with an immutable subject: names are followed by their numeric IDs.
  repos = { for stack in local.stacks : stack => "${var.github_org}@${var.github_owner_id}/${var.repositories[stack]}@${var.repository_ids[stack]}" }

  # The `sub` claim depends on how the job runs:
  #   pull_request event          -> repo:<org>@<id>/<repo>@<id>:pull_request
  #   job with `environment:`     -> repo:<org>@<id>/<repo>@<id>:environment:<name>
  #   push/schedule/dispatch with
  #   no environment              -> repo:<org>@<id>/<repo>@<id>:ref:refs/heads/<branch>
  sub_pull_request = { for stack, repo in local.repos : stack => "repo:${repo}:pull_request" }
  sub_environment  = { for stack, repo in local.repos : stack => "repo:${repo}:environment:${local.env}" }
  sub_branch       = { for stack, repo in local.repos : stack => "repo:${repo}:ref:refs/heads/${var.branch}" }

  role_subs = {
    "${local.rp}-platform-plan"  = [local.sub_pull_request["platform"], local.sub_branch["platform"]]
    "${local.rp}-platform-apply" = [local.sub_environment["platform"]]
    "${local.rp}-legacy-plan"    = [local.sub_pull_request["legacy"], local.sub_branch["legacy"]]
    "${local.rp}-legacy-apply"   = [local.sub_environment["legacy"]]
    "${local.rp}-legacy-deploy"  = [local.sub_environment["legacy"]]
    "${local.rp}-modern-plan"    = [local.sub_pull_request["modern"], local.sub_branch["modern"]]
    "${local.rp}-modern-apply"   = [local.sub_environment["modern"]]
    "${local.rp}-modern-release" = [local.sub_branch["modern"]]
    "${local.rp}-modern-deploy"  = [local.sub_environment["modern"]]
  }

  # Resources the bootstrap owns. platform-apply must not be able to change them.
  bootstrap_role_arns = concat(
    [for name in keys(local.role_subs) : "arn:${local.p}:iam::${local.a}:role/${name}"],
    [local.seed_role_arn],
  )

  # Keys created by bootstrap and platform; the legacy and modern pipelines must not touch them.
  platform_key_aliases = [
    "alias/shiptrack-data",
    "alias/shiptrack-secrets",
    "alias/shiptrack-logs",
    "alias/shiptrack-tfstate",
  ]

  secrets_prefix = "arn:${local.p}:secretsmanager:${local.r}:${local.a}:secret:shiptrack/${local.env}"
  ssm_prefix     = "arn:${local.p}:ssm:${local.r}:${local.a}:parameter/shiptrack"
  all_keys_arn   = "arn:${local.p}:kms:${local.r}:${local.a}:key/*"

  managed = {
    read_only  = "arn:${local.p}:iam::aws:policy/ReadOnlyAccess"
    power_user = "arn:${local.p}:iam::aws:policy/PowerUserAccess"
  }
}
