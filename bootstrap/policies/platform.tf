data "aws_iam_policy_document" "platform_plan" {
  source_policy_documents = [
    data.aws_iam_policy_document.state_plan["platform"].json,
    data.aws_iam_policy_document.token_read.json,
    data.aws_iam_policy_document.db_secrets_read.json,
  ]
}

data "aws_iam_policy_document" "platform_apply" {
  source_policy_documents = [data.aws_iam_policy_document.state_apply["platform"].json]

  # PowerUserAccess covers everything except IAM. IAM writes are limited to names under the role prefix.
  statement {
    sid = "ManageShiptrackIam"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:PassRole",
    ]
    resources = [
      "arn:${local.p}:iam::${local.a}:role/${local.rp}-*",
      "arn:${local.p}:iam::${local.a}:policy/${local.rp}-*",
      "arn:${local.p}:iam::${local.a}:instance-profile/${local.rp}-*",
    ]
  }

  # The roles, boundary, and state that bootstrap owns are out of reach of the platform pipeline.
  statement {
    sid    = "DenyChangingBootstrapIam"
    effect = "Deny"
    actions = [
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePermissionsBoundary",
      "iam:DeleteRolePermissionsBoundary",
    ]
    resources = local.bootstrap_role_arns
  }

  statement {
    sid    = "DenyChangingTheBoundary"
    effect = "Deny"
    actions = [
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [local.boundary_arn]
  }

  statement {
    sid    = "DenyChangingOtherStacksState"
    effect = "Deny"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]
    resources = [
      "${var.state_bucket_arn}/bootstrap/*",
      "${var.state_bucket_arn}/legacy/*",
      "${var.state_bucket_arn}/modern/*",
    ]
  }

  statement {
    sid    = "DenyChangingTheStateBucket"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:PutEncryptionConfiguration",
      "s3:PutBucketVersioning",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketOwnershipControls",
    ]
    resources = [var.state_bucket_arn]
  }

  statement {
    sid    = "DenyChangingTheStateKey"
    effect = "Deny"
    actions = [
      "kms:ScheduleKeyDeletion",
      "kms:DisableKey",
      "kms:DisableKeyRotation",
      "kms:PutKeyPolicy",
    ]
    resources = [var.state_kms_key_arn]
  }
}
