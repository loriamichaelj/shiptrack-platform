# Offline: the provider is mocked, so nothing contacts AWS.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:123456789012:mock-topic" }
  }
}

override_resource {
  target          = aws_sns_topic.alerts["sev1"]
  override_during = plan
  values          = { arn = "arn:aws:sns:us-east-1:123456789012:shiptrack-alerts-sev1" }
}

override_resource {
  target          = aws_sns_topic.alerts["sev2"]
  override_during = plan
  values          = { arn = "arn:aws:sns:us-east-1:123456789012:shiptrack-alerts-sev2" }
}

variables {
  logs_key_arn   = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000c"
  runbook_url    = "https://runbooks.example.test/cutover.md"
  alb_arn_suffix = "app/shiptrack-alb/0123456789abcdef"
  target_groups = {
    legacy = "targetgroup/shiptrack-tg-legacy/0000000000000001"
    modern = "targetgroup/shiptrack-tg-modern/0000000000000002"
  }
  db_instance_id     = "shiptrack-db"
  db_max_connections = 400
  cutover = {
    track   = { legacy = 90, modern = 10 }
    default = { legacy = 100, modern = 0 }
  }
}

run "topics_are_encrypted_with_the_logs_key" {
  command = plan

  assert {
    condition = alltrue([
      aws_sns_topic.alerts["sev1"].name == "shiptrack-alerts-sev1",
      aws_sns_topic.alerts["sev2"].name == "shiptrack-alerts-sev2",
      aws_sns_topic.alerts["sev1"].kms_master_key_id == var.logs_key_arn,
      aws_sns_topic.alerts["sev2"].kms_master_key_id == var.logs_key_arn,
    ])
    error_message = "Both topics must be named shiptrack-alerts-sev1/2 and use the logs key, because alarms cannot publish to AWS-managed-key topics."
  }
}

run "every_alarm_names_its_owner_severity_and_runbook" {
  command = plan

  assert {
    condition = alltrue([
      for a in concat(
        values(aws_cloudwatch_metric_alarm.tg_5xx_ratio),
        values(aws_cloudwatch_metric_alarm.tg_p99_latency),
        values(aws_cloudwatch_metric_alarm.tg_unhealthy_hosts),
        [
          aws_cloudwatch_metric_alarm.alb_elb_5xx,
          aws_cloudwatch_metric_alarm.rds_cpu,
          aws_cloudwatch_metric_alarm.rds_free_storage,
          aws_cloudwatch_metric_alarm.rds_connections,
          aws_cloudwatch_metric_alarm.rds_freeable_memory,
        ],
      ) : can(regex("^owner: platform \\| severity: SEV[12] \\| runbook: https://[^ ]+#[a-z0-9-]+ \\|", a.alarm_description))
    ])
    error_message = "Every alarm description must contain owner, severity, and a runbook URL with the alarm as the anchor."
  }
}

run "every_alarm_has_alarm_and_ok_actions_and_quiet_missing_data" {
  command = plan

  assert {
    condition = alltrue([
      for a in concat(
        values(aws_cloudwatch_metric_alarm.tg_5xx_ratio),
        values(aws_cloudwatch_metric_alarm.tg_p99_latency),
        values(aws_cloudwatch_metric_alarm.tg_unhealthy_hosts),
        [
          aws_cloudwatch_metric_alarm.alb_elb_5xx,
          aws_cloudwatch_metric_alarm.rds_cpu,
          aws_cloudwatch_metric_alarm.rds_free_storage,
          aws_cloudwatch_metric_alarm.rds_connections,
          aws_cloudwatch_metric_alarm.rds_freeable_memory,
        ],
      ) : length(a.alarm_actions) == 1 && length(a.ok_actions) == 1 && a.alarm_actions == a.ok_actions && a.treat_missing_data == "notBreaching"
    ])
    error_message = "Every alarm needs matching alarm and OK actions and treat_missing_data = notBreaching."
  }
}

run "severities_go_to_the_right_topic" {
  command = plan

  assert {
    condition = alltrue([
      alltrue([for a in aws_cloudwatch_metric_alarm.tg_5xx_ratio : endswith(one(a.alarm_actions), "alerts-sev1")]),
      endswith(one(aws_cloudwatch_metric_alarm.alb_elb_5xx.alarm_actions), "alerts-sev1"),
      alltrue([for a in aws_cloudwatch_metric_alarm.tg_p99_latency : endswith(one(a.alarm_actions), "alerts-sev2")]),
      alltrue([for a in aws_cloudwatch_metric_alarm.tg_unhealthy_hosts : endswith(one(a.alarm_actions), "alerts-sev2")]),
      endswith(one(aws_cloudwatch_metric_alarm.rds_cpu.alarm_actions), "alerts-sev2"),
      endswith(one(aws_cloudwatch_metric_alarm.rds_connections.alarm_actions), "alerts-sev2"),
    ])
    error_message = "The 5xx alarms are SEV1; latency, unhealthy hosts, and the database alarms are SEV2."
  }

  assert {
    condition = alltrue([
      alltrue([for a in aws_cloudwatch_metric_alarm.tg_5xx_ratio : can(regex("severity: SEV1", a.alarm_description))]),
      can(regex("severity: SEV1", aws_cloudwatch_metric_alarm.alb_elb_5xx.alarm_description)),
      alltrue([for a in aws_cloudwatch_metric_alarm.tg_p99_latency : can(regex("severity: SEV2", a.alarm_description))]),
      can(regex("severity: SEV2", aws_cloudwatch_metric_alarm.rds_cpu.alarm_description)),
    ])
    error_message = "The severity in each description must match its topic."
  }
}

run "thresholds_follow_the_design" {
  command = plan

  assert {
    condition = alltrue([
      alltrue([for a in aws_cloudwatch_metric_alarm.tg_5xx_ratio : a.threshold == 2 && a.datapoints_to_alarm == 3 && a.evaluation_periods == 5]),
      alltrue([for a in aws_cloudwatch_metric_alarm.tg_p99_latency : a.threshold == 1 && a.extended_statistic == "p99" && a.datapoints_to_alarm == 5 && a.evaluation_periods == 5]),
      alltrue([for a in aws_cloudwatch_metric_alarm.tg_unhealthy_hosts : a.threshold == 0 && a.evaluation_periods == 5]),
      aws_cloudwatch_metric_alarm.alb_elb_5xx.threshold == 10,
      aws_cloudwatch_metric_alarm.alb_elb_5xx.datapoints_to_alarm == 3,
      aws_cloudwatch_metric_alarm.rds_cpu.threshold == 80,
      aws_cloudwatch_metric_alarm.rds_cpu.period * aws_cloudwatch_metric_alarm.rds_cpu.evaluation_periods == 900,
      aws_cloudwatch_metric_alarm.rds_free_storage.threshold == 10737418240,
      aws_cloudwatch_metric_alarm.rds_connections.threshold == 320,
      aws_cloudwatch_metric_alarm.rds_freeable_memory.threshold == 268435456,
      aws_cloudwatch_metric_alarm.rds_freeable_memory.period * aws_cloudwatch_metric_alarm.rds_freeable_memory.evaluation_periods == 600,
    ])
    error_message = "Alarm thresholds and windows must match design §6.8."
  }
}

run "there_is_one_alarm_per_target_group_and_kind" {
  command = plan

  assert {
    condition = alltrue([
      toset(keys(aws_cloudwatch_metric_alarm.tg_5xx_ratio)) == toset(["legacy", "modern"]),
      toset(keys(aws_cloudwatch_metric_alarm.tg_p99_latency)) == toset(["legacy", "modern"]),
      toset(keys(aws_cloudwatch_metric_alarm.tg_unhealthy_hosts)) == toset(["legacy", "modern"]),
      aws_cloudwatch_metric_alarm.tg_5xx_ratio["legacy"].alarm_name == "shiptrack-tg-legacy-5xx-ratio",
    ])
    error_message = "Each target group needs the 5xx-ratio, p99-latency, and unhealthy-hosts alarms."
  }
}

run "both_topics_have_a_policy" {
  command = plan

  assert {
    condition     = length(aws_sns_topic_policy.alerts) == 2
    error_message = "Both topics carry a policy; sev2 adds the EventBridge statement, which is built from the policy document and is exercised by the first apply."
  }
}

run "the_dashboard_has_every_row_and_the_weights" {
  command = plan

  assert {
    condition     = can(jsondecode(aws_cloudwatch_dashboard.cutover.dashboard_body))
    error_message = "The dashboard body must be valid JSON."
  }

  assert {
    condition = alltrue([
      aws_cloudwatch_dashboard.cutover.dashboard_name == "shiptrack-cutover",
      length(jsondecode(aws_cloudwatch_dashboard.cutover.dashboard_body).widgets) == 11,
      length([for w in jsondecode(aws_cloudwatch_dashboard.cutover.dashboard_body).widgets : w if w.type == "text"]) == 1,
      toset([for w in jsondecode(aws_cloudwatch_dashboard.cutover.dashboard_body).widgets : w.y]) == toset([0, 3, 9, 15, 21, 27]),
    ])
    error_message = "The dashboard has a weights text widget and five metric rows."
  }

  assert {
    condition     = can(regex("\\| UI and track API \\| 90 \\| 10 \\|", one([for w in jsondecode(aws_cloudwatch_dashboard.cutover.dashboard_body).widgets : w.properties.markdown if w.type == "text"])))
    error_message = "The text widget must show the cutover weights."
  }
}

run "emails_are_split_trimmed_and_keyed_by_position" {
  command = plan

  variables {
    alert_emails = "a@example.test, b@example.test ,"
  }

  assert {
    condition = alltrue([
      toset(keys(aws_sns_topic_subscription.sev1)) == toset(["0", "1"]),
      toset(keys(aws_sns_topic_subscription.sev2)) == toset(["0", "1"]),
      aws_sns_topic_subscription.sev1["1"].endpoint == "b@example.test",
    ])
    error_message = "Subscriptions are keyed by position so the plan summary never shows an address."
  }
}

run "no_emails_means_no_subscriptions" {
  command = plan

  assert {
    condition     = length(aws_sns_topic_subscription.sev1) == 0 && length(aws_sns_topic_subscription.sev2) == 0
    error_message = "An empty alert_emails creates no subscriptions."
  }
}
