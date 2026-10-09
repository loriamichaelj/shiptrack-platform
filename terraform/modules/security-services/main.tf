# Account security services (design §6.7): CloudTrail, GuardDuty, AWS Config, Security Hub CSPM,
# Inspector, IAM Access Analyzer, and the routing of serious findings to the SEV2 topic. The unified
# Security Hub (OCSF) is out of scope; this uses Security Hub CSPM and its ASFF findings.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  partition = data.aws_partition.current.partition
  region    = data.aws_region.current.region

  # IAM and security groups change rarely and matter most, so they are recorded continuously; the
  # rest of the account is recorded daily to control cost.
  continuous_resource_types = [
    "AWS::IAM::Role",
    "AWS::IAM::Policy",
    "AWS::IAM::User",
    "AWS::IAM::Group",
    "AWS::EC2::SecurityGroup",
  ]
}

# --- CloudTrail ----------------------------------------------------------------------------------

resource "aws_cloudtrail" "this" {
  #checkov:skip=CKV_AWS_252: alerts come from GuardDuty and Security Hub findings, not from the trail's own SNS topic
  #checkov:skip=CKV2_AWS_10: CloudWatch Logs delivery of the trail is not part of the design
  name                          = var.trail_name
  s3_bucket_name                = var.cloudtrail_bucket_name
  kms_key_id                    = var.logs_key_arn
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  advanced_event_selector {
    name = "Management events"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  dynamic "advanced_event_selector" {
    for_each = var.enable_pod_data_events ? [1] : []

    content {
      name = "S3 data events for the POD bucket"

      field_selector {
        field  = "eventCategory"
        equals = ["Data"]
      }

      field_selector {
        field  = "resources.type"
        equals = ["AWS::S3::Object"]
      }

      field_selector {
        field       = "resources.ARN"
        starts_with = ["${var.pod_bucket_arn}/"]
      }
    }
  }
}

# --- GuardDuty -----------------------------------------------------------------------------------

resource "aws_guardduty_detector" "this" {
  #checkov:skip=CKV2_AWS_3: this is a single account with no AWS Organization (design §2), so there is no organisation configuration to set
  enable = true
}

resource "aws_guardduty_detector_feature" "s3" {
  detector_id = aws_guardduty_detector.this.id
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"

  # This feature has no settings of its own here. AWS reports agent-management settings on it, which
  # would otherwise show as a difference in every plan.
  lifecycle {
    ignore_changes = [additional_configuration]
  }
}

resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  detector_id = aws_guardduty_detector.this.id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"

  # This feature has no settings of its own here. AWS reports agent-management settings on it, which
  # would otherwise show as a difference in every plan.
  lifecycle {
    ignore_changes = [additional_configuration]
  }
}

resource "aws_guardduty_detector_feature" "rds_login_events" {
  detector_id = aws_guardduty_detector.this.id
  name        = "RDS_LOGIN_EVENTS"
  status      = "ENABLED"

  # This feature has no settings of its own here. AWS reports agent-management settings on it, which
  # would otherwise show as a difference in every plan.
  lifecycle {
    ignore_changes = [additional_configuration]
  }
}

resource "aws_guardduty_detector_feature" "runtime" {
  detector_id = aws_guardduty_detector.this.id
  name        = "RUNTIME_MONITORING"
  status      = var.enable_guardduty_runtime ? "ENABLED" : "DISABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = var.enable_guardduty_runtime ? "ENABLED" : "DISABLED"
  }

  # AWS reports all three agent-management settings for this feature, so all three are stated;
  # leaving two out makes every plan show a difference. Only EKS is used here.
  additional_configuration {
    name   = "ECS_FARGATE_AGENT_MANAGEMENT"
    status = "DISABLED"
  }

  additional_configuration {
    name   = "EC2_AGENT_MANAGEMENT"
    status = "DISABLED"
  }
}

# --- AWS Config ----------------------------------------------------------------------------------
# Required by Security Hub's controls. It delivers to the CloudTrail bucket under config/.

data "aws_iam_policy_document" "config_trust" {
  statement {
    actions = ["sts:AssumeRole"]

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

data "aws_iam_policy_document" "config_delivery" {
  statement {
    sid       = "ReadTheBucket"
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.cloudtrail_bucket_name}"]
  }

  statement {
    sid       = "WriteConfigObjects"
    actions   = ["s3:PutObject"]
    resources = ["arn:${local.partition}:s3:::${var.cloudtrail_bucket_name}/config/AWSLogs/${local.account}/Config/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid       = "UseTheLogsKey"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.logs_key_arn]
  }
}

resource "aws_iam_role" "config" {
  name               = "${var.role_prefix}-platform-config"
  assume_role_policy = data.aws_iam_policy_document.config_trust.json
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_delivery" {
  name   = "deliver-to-the-cloudtrail-bucket"
  role   = aws_iam_role.config.id
  policy = data.aws_iam_policy_document.config_delivery.json
}

resource "aws_config_configuration_recorder" "this" {
  name     = var.config_recorder_name
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }

  recording_mode {
    recording_frequency = "DAILY"

    recording_mode_override {
      description         = "IAM and security groups are recorded continuously"
      resource_types      = local.continuous_resource_types
      recording_frequency = "CONTINUOUS"
    }
  }
}

resource "aws_config_delivery_channel" "this" {
  name           = var.config_delivery_channel_name
  s3_bucket_name = var.cloudtrail_bucket_name
  s3_key_prefix  = "config"

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}

# --- Security Hub CSPM ---------------------------------------------------------------------------

resource "aws_securityhub_account" "this" {
  enable_default_standards  = false
  control_finding_generator = "SECURITY_CONTROL"

  depends_on = [aws_config_configuration_recorder_status.this]
}

resource "aws_securityhub_standards_subscription" "foundational" {
  standards_arn = "arn:${local.partition}:securityhub:${local.region}::standards/aws-foundational-security-best-practices/v/1.0.0"

  # A standard can take longer than the provider's three-minute default to become ready.
  timeouts {
    create = var.security_hub_timeout
    delete = var.security_hub_timeout
  }

  depends_on = [aws_securityhub_account.this]
}

# The standard's ARN is region-specific and version-pinned.
resource "aws_securityhub_standards_subscription" "cis" {
  standards_arn = "arn:${local.partition}:securityhub:${local.region}::standards/cis-aws-foundations-benchmark/v/3.0.0"

  timeouts {
    create = var.security_hub_timeout
    delete = var.security_hub_timeout
  }

  depends_on = [aws_securityhub_account.this]
}

# --- Inspector -----------------------------------------------------------------------------------

resource "aws_inspector2_enabler" "this" {
  account_ids    = [local.account]
  resource_types = ["EC2", "ECR"]

  # Enabling or disabling EC2 scanning can take longer than the provider's five-minute default.
  timeouts {
    create = var.inspector_timeout
    delete = var.inspector_timeout
  }
}

# Enhanced scanning with continuous re-scan, for every repository in the registry.
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"

    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }

  depends_on = [aws_inspector2_enabler.this]
}

# --- IAM Access Analyzer -------------------------------------------------------------------------

resource "aws_accessanalyzer_analyzer" "this" {
  count = var.manage_access_analyzer ? 1 : 0

  analyzer_name = "${var.name_prefix}-analyzer"
  type          = "ACCOUNT"
}

# --- Findings routing ----------------------------------------------------------------------------
# New CRITICAL and HIGH findings go to the SEV2 topic, whose policy lets EventBridge publish.

resource "aws_cloudwatch_event_rule" "findings" {
  name        = "${var.name_prefix}-securityhub-high-findings"
  description = "owner: platform | severity: SEV2 | New CRITICAL and HIGH Security Hub findings"

  event_pattern = jsonencode({
    source        = ["aws.securityhub"]
    "detail-type" = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        Severity = { Label = ["CRITICAL", "HIGH"] }
        Workflow = { Status = ["NEW"] }
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "findings" {
  rule      = aws_cloudwatch_event_rule.findings.name
  target_id = "sev2-topic"
  arn       = var.sns_sev2_arn
}
