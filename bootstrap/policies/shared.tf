# Building blocks shared by several roles.

# Plan roles read state and write only the lock object: S3 native locking writes a .tflock file
# even during `plan`.
data "aws_iam_policy_document" "state_plan" {
  for_each = toset(local.stacks)

  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.state_bucket_arn]
  }

  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["${var.state_bucket_arn}/${each.key}/*"]
  }

  statement {
    sid       = "WriteLockFile"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.state_bucket_arn}/${each.key}/*.tflock"]
  }

  statement {
    sid       = "UseStateKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [var.state_kms_key_arn]
  }
}

data "aws_iam_policy_document" "state_apply" {
  for_each = toset(local.stacks)

  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.state_bucket_arn]
  }

  statement {
    sid       = "ReadWriteState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.state_bucket_arn}/${each.key}/*"]
  }

  statement {
    sid       = "UseStateKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [var.state_kms_key_arn]
  }
}

# The test-routing token lets CI address one stack directly through the ALB.
data "aws_iam_policy_document" "token_read" {
  statement {
    sid       = "ReadTestRoutingToken"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["${local.secrets_prefix}/test-routing-token-*"]
  }

  statement {
    sid       = "DecryptSecretsThroughSecretsManager"
    actions   = ["kms:Decrypt"]
    resources = [local.all_keys_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.r}.amazonaws.com"]
    }
  }
}

# Refreshing aws_secretsmanager_secret_version reads the secret value, so the platform plan role
# can read the database secrets. See risk R-09 in the platform design.
data "aws_iam_policy_document" "db_secrets_read" {
  statement {
    sid       = "ReadDatabaseSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["${local.secrets_prefix}/db/*"]
  }
}

# The legacy and modern pipelines must not be able to change the platform's keys.
data "aws_iam_policy_document" "deny_platform_key_changes" {
  statement {
    sid    = "DenyChangingPlatformKeys"
    effect = "Deny"
    actions = [
      "kms:ScheduleKeyDeletion",
      "kms:DisableKey",
      "kms:DisableKeyRotation",
      "kms:PutKeyPolicy",
    ]
    resources = ["*"]

    condition {
      test     = "ForAnyValue:StringLike"
      variable = "kms:ResourceAliases"
      values   = local.platform_key_aliases
    }
  }
}
