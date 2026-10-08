# The Terraform state bucket and its customer-managed key. On the first run, ci.sh creates only
# aws_s3_bucket.state (-target) and moves state into it before anything else is created.

data "aws_iam_policy_document" "key" {
  # Root delegation: access to the key is granted through IAM policies, not enumerated here.
  #checkov:skip=CKV_AWS_109: key policy delegates to IAM by design (root account principal)
  #checkov:skip=CKV_AWS_111: key policy delegates to IAM by design (root account principal)
  #checkov:skip=CKV_AWS_356: key policy resource "*" refers to this key
  statement {
    sid       = "EnableIamPolicies"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${var.partition}:iam::${var.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "state" {
  description             = "Encrypts Terraform state"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.key.json

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/shiptrack-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_18: access logging is not enabled; CloudTrail records access to the account
  #checkov:skip=CKV_AWS_144: cross-region replication is out of scope (single region, no DR)
  #checkov:skip=CKV2_AWS_62: event notifications are not needed for the state bucket
  #checkov:skip=CKV2_AWS_61: lifecycle configuration is defined in aws_s3_bucket_lifecycle_configuration.state
  bucket = var.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

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

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}
