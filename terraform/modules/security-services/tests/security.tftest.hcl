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
  role_prefix            = "testowner-dev-shiptrack"
  cloudtrail_bucket_name = "shiptrack-cloudtrail-mock"
  pod_bucket_arn         = "arn:aws:s3:::shiptrack-pod-mock"
  logs_key_arn           = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000c"
  sns_sev2_arn           = "arn:aws:sns:us-east-1:123456789012:shiptrack-alerts-sev2"
}

run "the_trail_follows_the_design" {
  command = plan

  assert {
    condition = alltrue([
      aws_cloudtrail.this.name == "shiptrack-trail",
      aws_cloudtrail.this.is_multi_region_trail,
      aws_cloudtrail.this.enable_log_file_validation,
      aws_cloudtrail.this.kms_key_id == var.logs_key_arn,
      aws_cloudtrail.this.s3_bucket_name == var.cloudtrail_bucket_name,
    ])
    error_message = "A multi-region trail with log-file validation, encrypted with the logs key."
  }

  assert {
    condition     = length(aws_cloudtrail.this.advanced_event_selector) == 1
    error_message = "Only management events by default; S3 data events are off."
  }
}

run "pod_data_events_when_enabled" {
  command = plan

  variables {
    enable_pod_data_events = true
  }

  assert {
    condition = alltrue([
      length(aws_cloudtrail.this.advanced_event_selector) == 2,
      anytrue([
        for s in aws_cloudtrail.this.advanced_event_selector :
        anytrue([for f in s.field_selector : f.field == "resources.ARN" && try(contains(tolist(f.starts_with), "arn:aws:s3:::shiptrack-pod-mock/"), false)])
      ]),
    ])
    error_message = "The data-event selector is limited to objects in the POD bucket."
  }
}

run "guardduty_features" {
  command = plan

  assert {
    condition = alltrue([
      aws_guardduty_detector.this.enable,
      aws_guardduty_detector_feature.s3.name == "S3_DATA_EVENTS" && aws_guardduty_detector_feature.s3.status == "ENABLED",
      aws_guardduty_detector_feature.eks_audit_logs.status == "ENABLED",
      aws_guardduty_detector_feature.rds_login_events.status == "ENABLED",
      aws_guardduty_detector_feature.runtime.name == "RUNTIME_MONITORING",
      aws_guardduty_detector_feature.runtime.status == "ENABLED",
      { for c in aws_guardduty_detector_feature.runtime.additional_configuration : c.name => c.status } == {
        EKS_ADDON_MANAGEMENT         = "ENABLED"
        ECS_FARGATE_AGENT_MANAGEMENT = "DISABLED"
        EC2_AGENT_MANAGEMENT         = "DISABLED"
      },
    ])
    error_message = "S3, EKS audit, RDS login, and Runtime Monitoring with automated EKS agent management."
  }
}

run "runtime_monitoring_can_be_turned_off" {
  command = plan

  variables {
    enable_guardduty_runtime = false
  }

  assert {
    condition = alltrue([
      aws_guardduty_detector_feature.runtime.status == "DISABLED",
      alltrue([for c in aws_guardduty_detector_feature.runtime.additional_configuration : c.status == "DISABLED"]),
    ])
    error_message = "enable_guardduty_runtime = false turns the feature and its agent management off."
  }
}

run "config_records_daily_with_continuous_overrides" {
  command = plan

  assert {
    condition = alltrue([
      one(aws_config_configuration_recorder.this.recording_mode).recording_frequency == "DAILY",
      one(one(aws_config_configuration_recorder.this.recording_mode).recording_mode_override).recording_frequency == "CONTINUOUS",
      one(one(aws_config_configuration_recorder.this.recording_mode).recording_mode_override).resource_types == toset([
        "AWS::IAM::Role", "AWS::IAM::Policy", "AWS::IAM::User", "AWS::IAM::Group", "AWS::EC2::SecurityGroup",
      ]),
      one(aws_config_configuration_recorder.this.recording_group).all_supported,
    ])
    error_message = "Daily recording, with IAM and security groups continuous."
  }

  assert {
    condition = alltrue([
      aws_config_delivery_channel.this.s3_bucket_name == var.cloudtrail_bucket_name,
      aws_config_delivery_channel.this.s3_key_prefix == "config",
      aws_config_configuration_recorder_status.this.is_enabled,
      aws_iam_role.config.name == "testowner-dev-shiptrack-platform-config",
      aws_config_configuration_recorder.this.name == "shiptrack-recorder",
      aws_config_delivery_channel.this.name == "shiptrack-delivery",
    ])
    error_message = "Config delivers to the CloudTrail bucket under config/, runs, and uses a role named under the prefix."
  }
}

run "security_hub_standards" {
  command = plan

  assert {
    condition = alltrue([
      !aws_securityhub_account.this.enable_default_standards,
      aws_securityhub_standards_subscription.foundational.standards_arn == "arn:aws:securityhub:us-east-1::standards/aws-foundational-security-best-practices/v/1.0.0",
      aws_securityhub_standards_subscription.cis.standards_arn == "arn:aws:securityhub:us-east-1::standards/cis-aws-foundations-benchmark/v/3.0.0",
    ])
    error_message = "Only the Foundational Security Best Practices and CIS v3.0 standards are subscribed."
  }
}

run "inspector_and_access_analyzer" {
  command = plan

  assert {
    condition = alltrue([
      aws_inspector2_enabler.this.resource_types == toset(["EC2", "ECR"]),
      aws_ecr_registry_scanning_configuration.this.scan_type == "ENHANCED",
      one(aws_ecr_registry_scanning_configuration.this.rule).scan_frequency == "CONTINUOUS_SCAN",
      one(aws_accessanalyzer_analyzer.this).type == "ACCOUNT",
    ])
    error_message = "Inspector scans EC2 and ECR (enhanced, continuous), and an account analyzer runs."
  }
}

run "serious_findings_go_to_the_sev2_topic" {
  command = plan

  assert {
    condition = alltrue([
      jsondecode(aws_cloudwatch_event_rule.findings.event_pattern).source == ["aws.securityhub"],
      jsondecode(aws_cloudwatch_event_rule.findings.event_pattern).detail.findings.Severity.Label == ["CRITICAL", "HIGH"],
      jsondecode(aws_cloudwatch_event_rule.findings.event_pattern).detail.findings.Workflow.Status == ["NEW"],
      aws_cloudwatch_event_target.findings.arn == var.sns_sev2_arn,
    ])
    error_message = "New CRITICAL and HIGH findings reach the SEV2 topic."
  }
}

run "an_existing_config_setup_keeps_its_names" {
  command = plan

  variables {
    config_recorder_name         = "default"
    config_delivery_channel_name = "default"
  }

  assert {
    condition = alltrue([
      aws_config_configuration_recorder.this.name == "default",
      aws_config_delivery_channel.this.name == "default",
      aws_config_configuration_recorder_status.this.name == "default",
    ])
    error_message = "The names are variables, so an existing recorder and channel can be adopted under their own names."
  }
}

run "no_second_access_analyzer_when_the_account_has_one" {
  command = plan

  variables {
    manage_access_analyzer = false
  }

  assert {
    condition     = length(aws_accessanalyzer_analyzer.this) == 0
    error_message = "manage_access_analyzer = false creates no analyzer."
  }
}

run "inspector_waits_longer_than_the_default" {
  command = plan

  assert {
    condition     = var.inspector_timeout == "20m"
    error_message = "Enabling EC2 scanning can take longer than five minutes."
  }
}

run "slow_services_get_longer_timeouts" {
  command = plan

  assert {
    condition     = var.inspector_timeout == "20m" && var.security_hub_timeout == "20m"
    error_message = "Inspector and Security Hub can take longer than the provider's defaults to settle."
  }
}
