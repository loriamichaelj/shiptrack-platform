# Permission boundary for every IAM role created by the legacy and modern pipelines. A boundary
# is an intersection with the role's own policy: an action missing here fails at runtime with
# AccessDenied, not at apply time.

locals {
  boundary_services = [
    "ec2", "autoscaling", "elasticloadbalancing", "eks", "eks-auth", "ecr", "sqs", "events",
    "s3", "secretsmanager", "kms", "ssm", "ssmmessages", "ec2messages", "cloudwatch", "logs",
    "aps", "xray", "sts", "pricing", "tag",
    # The last four appear as read and associate actions in the vendored AWS Load Balancer
    # Controller policy.
    "acm", "cognito-idp", "wafv2", "waf-regional", "shield",
  ]
}

# A permission boundary is an allow-list of service namespaces; the roles it caps carry the
# narrower resource-scoped policies. iam:PassRole is limited to shiptrack-* roles (AWS-0342).
#trivy:ignore:AWS-0345
#trivy:ignore:AWS-0342
data "aws_iam_policy_document" "boundary" {
  #checkov:skip=CKV_AWS_107: a permission boundary is an allow-list of service namespaces by design
  #checkov:skip=CKV_AWS_108: a permission boundary is an allow-list of service namespaces by design
  #checkov:skip=CKV_AWS_109: a permission boundary is an allow-list of service namespaces by design
  #checkov:skip=CKV_AWS_110: a permission boundary is an allow-list of service namespaces by design
  #checkov:skip=CKV_AWS_111: a permission boundary is an allow-list of service namespaces by design
  #checkov:skip=CKV_AWS_356: a permission boundary is an allow-list of service namespaces by design
  statement {
    sid       = "AllowedServices"
    actions   = [for service in local.boundary_services : "${service}:*"]
    resources = ["*"]
  }

  statement {
    sid       = "IamReadOnly"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  statement {
    sid       = "PassShiptrackRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.p}:iam::${local.a}:role/shiptrack-*"]
  }

  # Karpenter creates instance profiles at runtime.
  statement {
    sid = "InstanceProfiles"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
    ]
    resources = ["arn:${local.p}:iam::${local.a}:instance-profile/*"]
  }

  statement {
    sid    = "DenyAccountSecurityServices"
    effect = "Deny"
    actions = [
      "cloudtrail:Delete*", "cloudtrail:Stop*", "cloudtrail:Update*", "cloudtrail:Put*",
      "guardduty:Delete*", "guardduty:Disassociate*", "guardduty:Stop*", "guardduty:Update*",
      "config:Delete*", "config:Stop*", "config:Put*",
      "securityhub:Delete*", "securityhub:Disable*", "securityhub:Update*",
      "inspector2:Disable*", "inspector2:Delete*", "inspector2:Update*",
      "access-analyzer:Delete*", "access-analyzer:Update*",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "DenyIamUsersAndKeys"
    effect    = "Deny"
    actions   = ["iam:CreateUser", "iam:CreateAccessKey"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyBoundaryChanges"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary",
      "iam:PutRolePermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary",
      "iam:PutUserPermissionsBoundary",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyEditingTheBoundary"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
    ]
    resources = [local.boundary_arn]
  }

  statement {
    sid       = "DenyDeletingPlatformKeys"
    effect    = "Deny"
    actions   = ["kms:ScheduleKeyDeletion"]
    resources = ["*"]

    condition {
      test     = "ForAnyValue:StringLike"
      variable = "kms:ResourceAliases"
      values   = local.platform_key_aliases
    }
  }

  statement {
    sid       = "DenyOrganizations"
    effect    = "Deny"
    actions   = ["organizations:*"]
    resources = ["*"]
  }
}
