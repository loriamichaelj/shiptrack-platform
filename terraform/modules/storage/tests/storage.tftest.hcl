# Offline: the provider is mocked, so nothing contacts AWS.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  data_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000a"
  logs_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000c"
}

run "bucket_names_follow_the_design" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket.pod.bucket == "shiptrack-pod-123456789012-us-east-1",
      aws_s3_bucket.alb_logs.bucket == "shiptrack-alb-logs-123456789012-us-east-1",
      aws_s3_bucket.cloudtrail.bucket == "shiptrack-cloudtrail-123456789012-us-east-1",
    ])
    error_message = "Buckets must be named shiptrack-<purpose>-<account>-<region>."
  }
}

run "every_bucket_is_locked_down" {
  command = plan

  assert {
    condition = alltrue([
      for b in [
        aws_s3_bucket_public_access_block.pod,
        aws_s3_bucket_public_access_block.alb_logs,
        aws_s3_bucket_public_access_block.cloudtrail,
      ] : b.block_public_acls && b.block_public_policy && b.ignore_public_acls && b.restrict_public_buckets
    ])
    error_message = "Every bucket must block all public access."
  }

  assert {
    condition = alltrue([
      for o in [
        aws_s3_bucket_ownership_controls.pod,
        aws_s3_bucket_ownership_controls.alb_logs,
        aws_s3_bucket_ownership_controls.cloudtrail,
      ] : one(o.rule).object_ownership == "BucketOwnerEnforced"
    ])
    error_message = "Every bucket must enforce bucket-owner ownership."
  }
}

run "pod_bucket_encryption_and_versioning" {
  command = plan

  assert {
    condition = alltrue([
      one(aws_s3_bucket_server_side_encryption_configuration.pod.rule).bucket_key_enabled,
      one(one(aws_s3_bucket_server_side_encryption_configuration.pod.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms",
      one(one(aws_s3_bucket_server_side_encryption_configuration.pod.rule).apply_server_side_encryption_by_default).kms_master_key_id == var.data_key_arn,
    ])
    error_message = "The POD bucket uses SSE-KMS with the data key and S3 Bucket Keys."
  }

  assert {
    condition     = one(aws_s3_bucket_versioning.pod.versioning_configuration).status == "Enabled"
    error_message = "The POD bucket must be versioned."
  }
}

run "log_bucket_encryption" {
  command = plan

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.alb_logs.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "ALB access logs do not support SSE-KMS, so the bucket must use SSE-S3."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.cloudtrail.rule).apply_server_side_encryption_by_default).kms_master_key_id == var.logs_key_arn
    error_message = "The CloudTrail bucket uses the logs key."
  }
}

run "pod_lifecycle_follows_the_design" {
  command = plan

  assert {
    condition = alltrue([
      anytrue([for r in aws_s3_bucket_lifecycle_configuration.pod.rule : r.id == "age-out-current-versions" && one(r.expiration).days == 2555]),
      anytrue([for r in aws_s3_bucket_lifecycle_configuration.pod.rule : r.id == "age-out-current-versions" && toset([for t in r.transition : "${t.days}:${t.storage_class}"]) == toset(["30:STANDARD_IA", "90:GLACIER_IR"])]),
      anytrue([for r in aws_s3_bucket_lifecycle_configuration.pod.rule : r.id == "expire-noncurrent-versions" && one(r.noncurrent_version_expiration).noncurrent_days == 30]),
      anytrue([for r in aws_s3_bucket_lifecycle_configuration.pod.rule : r.id == "abort-incomplete-uploads" && one(r.abort_incomplete_multipart_upload).days_after_initiation == 7]),
    ])
    error_message = "POD lifecycle: IA at 30 d, Glacier IR at 90 d, expire at the retention, noncurrent at 30 d, multipart at 7 d."
  }
}

run "log_lifecycles_follow_the_design" {
  command = plan

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.alb_logs.rule).expiration).days == 90
    error_message = "ALB logs expire at 90 days."
  }

  assert {
    condition = alltrue([
      one(one(aws_s3_bucket_lifecycle_configuration.cloudtrail.rule).expiration).days == 365,
      one(one(aws_s3_bucket_lifecycle_configuration.cloudtrail.rule).transition).days == 30,
      one(one(aws_s3_bucket_lifecycle_configuration.cloudtrail.rule).transition).storage_class == "STANDARD_IA",
    ])
    error_message = "CloudTrail logs move to IA at 30 days and expire at 365."
  }
}

run "retention_must_outlast_the_glacier_transition" {
  command = plan

  variables {
    pod_retention_days = 60
  }

  expect_failures = [var.pod_retention_days]
}
