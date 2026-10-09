# The POD, ALB access-log, and CloudTrail buckets (design §6.5). Every bucket blocks public access,
# enforces bucket-owner ownership, and refuses requests that are not over TLS.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  partition = data.aws_partition.current.partition
  region    = data.aws_region.current.region
  suffix    = "${local.account}-${local.region}"
}

# --- Proof of delivery ---------------------------------------------------------------------------

resource "aws_s3_bucket" "pod" {
  #checkov:skip=CKV_AWS_18: server access logging is not part of the design; object access is audited through CloudTrail
  #checkov:skip=CKV2_AWS_62: event notifications are not needed for the POD bucket
  #checkov:skip=CKV_AWS_144: cross-region replication is out of scope (design §2, no multi-region DR)
  bucket = "${var.name_prefix}-pod-${local.suffix}"
}

resource "aws_s3_bucket_public_access_block" "pod" {
  bucket                  = aws_s3_bucket.pod.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "pod" {
  bucket = aws_s3_bucket.pod.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "pod" {
  bucket = aws_s3_bucket.pod.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Bucket default encryption enforces SSE-KMS, so the policy does not demand an encryption header:
# that would reject clients that rely on the default.
resource "aws_s3_bucket_server_side_encryption_configuration" "pod" {
  bucket = aws_s3_bucket.pod.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.data_key_arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "pod" {
  bucket = aws_s3_bucket.pod.id

  rule {
    id     = "age-out-current-versions"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = var.pod_retention_days
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.pod]
}

data "aws_iam_policy_document" "pod" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.pod.arn, "${aws_s3_bucket.pod.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "pod" {
  bucket = aws_s3_bucket.pod.id
  policy = data.aws_iam_policy_document.pod.json

  depends_on = [aws_s3_bucket_public_access_block.pod]
}

# --- ALB access logs -----------------------------------------------------------------------------
# ALB access logs do not support SSE-KMS, so this bucket uses SSE-S3.

resource "aws_s3_bucket" "alb_logs" {
  #checkov:skip=CKV_AWS_18: this is itself a log bucket; logging a log bucket adds nothing
  #checkov:skip=CKV_AWS_21: log objects are written once and expire after 90 days, so versions add nothing
  #checkov:skip=CKV_AWS_145: ALB access logs do not support SSE-KMS, so the bucket uses SSE-S3 (design §6.5)
  #checkov:skip=CKV2_AWS_62: event notifications are not needed for a log bucket
  #checkov:skip=CKV_AWS_144: cross-region replication is out of scope (design §2, no multi-region DR)
  bucket = "${var.name_prefix}-alb-logs-${local.suffix}"
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ALB access logs do not support SSE-KMS, so the bucket uses SSE-S3 (design §6.5) (AWS-0132).
#trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-after-90-days"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # The log-delivery service principal works in every region and replaces the per-region ELB
  # account IDs that regions opened before August 2022 needed. Only load balancers in this
  # account and region may write.
  statement {
    sid       = "AllowAlbLogDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${local.account}/*"]

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account}:loadbalancer/app/*"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs.json

  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

# --- CloudTrail (and AWS Config) -----------------------------------------------------------------

resource "aws_s3_bucket" "cloudtrail" {
  #checkov:skip=CKV_AWS_18: this is itself a log bucket; logging a log bucket adds nothing
  #checkov:skip=CKV_AWS_21: trail log files are written once and expire after a year, so versions add nothing
  #checkov:skip=CKV2_AWS_62: event notifications are not needed for a log bucket
  #checkov:skip=CKV_AWS_144: cross-region replication is out of scope (design §2, no multi-region DR)
  bucket = "${var.name_prefix}-cloudtrail-${local.suffix}"
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.logs_key_arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "age-out-trail-logs"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "cloudtrail" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.cloudtrail.arn, "${aws_s3_bucket.cloudtrail.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:cloudtrail:${local.region}:${local.account}:trail/${var.trail_name}"]
    }
  }

  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${local.account}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:cloudtrail:${local.region}:${local.account}:trail/${var.trail_name}"]
    }
  }

  # AWS Config delivers its snapshots and history to this bucket as well.
  statement {
    sid       = "ConfigAclCheck"
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.cloudtrail.arn]

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

  statement {
    sid     = "ConfigWrite"
    actions = ["s3:PutObject"]
    # AWS Config delivers under the config/ prefix that modules/security-services sets.
    resources = [
      "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${local.account}/Config/*",
      "${aws_s3_bucket.cloudtrail.arn}/config/AWSLogs/${local.account}/Config/*",
    ]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail.json

  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}
