# The three platform keys (design §6.3). Each key policy delegates to IAM in the account, so access
# is granted by IAM policies in the roles that need it, conditioned on kms:ViaService. Cross-repo
# role ARNs are never listed here. The logs key also grants the AWS services that write encrypted
# data on the account's behalf.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  partition = data.aws_partition.current.partition
  region    = data.aws_region.current.region
}

data "aws_iam_policy_document" "root_delegation" {
  #checkov:skip=CKV_AWS_109: a key policy applies to its own key, so "*" is the key itself; the root statement delegates to IAM (design §6.3)
  #checkov:skip=CKV_AWS_111: a key policy applies to its own key, so "*" is the key itself; the root statement delegates to IAM (design §6.3)
  #checkov:skip=CKV_AWS_356: a key policy applies to its own key, so "*" is the key itself
  statement {
    sid       = "DelegateToIam"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account}:root"]
    }
  }
}

data "aws_iam_policy_document" "logs" {
  #checkov:skip=CKV_AWS_109: a key policy applies to its own key, so "*" is the key itself; the root statement delegates to IAM (design §6.3)
  #checkov:skip=CKV_AWS_111: a key policy applies to its own key, so "*" is the key itself; the root statement delegates to IAM (design §6.3)
  #checkov:skip=CKV_AWS_356: a key policy applies to its own key, so "*" is the key itself
  source_policy_documents = [data.aws_iam_policy_document.root_delegation.json]

  statement {
    sid = "CloudWatchLogs"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account}:log-group:*"]
    }
  }

  # Encrypted SNS alarm topics: CloudWatch alarms and EventBridge publish to them, and SNS reads
  # the key to encrypt messages. EventBridge carries the Security Hub findings.
  statement {
    sid       = "AlarmTopics"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type = "Service"
      identifiers = [
        "cloudwatch.amazonaws.com",
        "sns.amazonaws.com",
        "events.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }

  statement {
    sid       = "CloudTrail"
    actions   = ["kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${local.partition}:cloudtrail:*:${local.account}:trail/*"]
    }
  }

  # AWS Config delivers to the CloudTrail bucket, which this key encrypts.
  statement {
    sid       = "Config"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }
}

resource "aws_kms_key" "data" {
  #checkov:skip=CKV_AWS_109: the policy delegates to IAM for the account; access is granted by IAM policies (design §6.3)
  #checkov:skip=CKV_AWS_111: the policy delegates to IAM for the account; access is granted by IAM policies (design §6.3)
  #checkov:skip=CKV2_AWS_64: the key policy is defined, and delegates to IAM for the account
  description             = "ShipTrack data: RDS storage and the POD bucket"
  enable_key_rotation     = true
  deletion_window_in_days = var.deletion_window_in_days
  policy                  = data.aws_iam_policy_document.root_delegation.json
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.name_prefix}-data"
  target_key_id = aws_kms_key.data.key_id
}

resource "aws_kms_key" "secrets" {
  #checkov:skip=CKV_AWS_109: the policy delegates to IAM for the account; access is granted by IAM policies (design §6.3)
  #checkov:skip=CKV_AWS_111: the policy delegates to IAM for the account; access is granted by IAM policies (design §6.3)
  #checkov:skip=CKV2_AWS_64: the key policy is defined, and delegates to IAM for the account
  description             = "ShipTrack secrets: Secrets Manager database secrets"
  enable_key_rotation     = true
  deletion_window_in_days = var.deletion_window_in_days
  policy                  = data.aws_iam_policy_document.root_delegation.json
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name_prefix}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

resource "aws_kms_key" "logs" {
  #checkov:skip=CKV_AWS_109: the policy delegates to IAM for the account; access is granted by IAM policies (design §6.3)
  #checkov:skip=CKV_AWS_111: the policy delegates to IAM for the account; access is granted by IAM policies (design §6.3)
  #checkov:skip=CKV2_AWS_64: the key policy is defined, and delegates to IAM for the account
  description             = "ShipTrack logs: CloudWatch Logs, SNS, CloudTrail"
  enable_key_rotation     = true
  deletion_window_in_days = var.deletion_window_in_days
  policy                  = data.aws_iam_policy_document.logs.json
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${var.name_prefix}-logs"
  target_key_id = aws_kms_key.logs.key_id
}
