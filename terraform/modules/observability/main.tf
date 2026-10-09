# Alert topics, platform-owned alarms, and the cutover dashboard (design §6.8). Every alarm
# description names its owner, severity, and runbook, and every alarm has both alarm and OK actions.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.region

  emails = { for i, e in compact([for e in split(",", var.alert_emails) : trimspace(e)]) : tostring(i) => e }

  topics = toset(["sev1", "sev2"])

  target_groups = var.target_groups
}

# --- Alert topics --------------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  for_each = local.topics

  name              = "${var.name_prefix}-alerts-${each.key}"
  kms_master_key_id = var.logs_key_arn
}

data "aws_iam_policy_document" "alerts" {
  for_each = local.topics

  # The statements SNS creates by default are replaced when a policy is set, so the account's own
  # publishers and subscribers are granted again here.
  statement {
    sid = "AccountOwnerManagesTheTopic"
    actions = [
      "sns:GetTopicAttributes",
      "sns:SetTopicAttributes",
      "sns:AddPermission",
      "sns:RemovePermission",
      "sns:DeleteTopic",
      "sns:Subscribe",
      "sns:ListSubscriptionsByTopic",
      "sns:Publish",
    ]
    resources = [aws_sns_topic.alerts[each.key].arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [local.account]
    }
  }

  statement {
    sid       = "CloudWatchAlarmsPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts[each.key].arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }

  # Security Hub findings reach sev2 through an EventBridge rule (design §6.7).
  dynamic "statement" {
    for_each = each.key == "sev2" ? [1] : []

    content {
      sid       = "EventBridgePublish"
      actions   = ["sns:Publish"]
      resources = [aws_sns_topic.alerts[each.key].arn]

      principals {
        type        = "Service"
        identifiers = ["events.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account]
      }
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  for_each = local.topics

  arn    = aws_sns_topic.alerts[each.key].arn
  policy = data.aws_iam_policy_document.alerts[each.key].json
}

# Keyed by position, not address, so the plan summary never shows an email address.
resource "aws_sns_topic_subscription" "sev1" {
  for_each = local.emails

  topic_arn = aws_sns_topic.alerts["sev1"].arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "sev2" {
  for_each = local.emails

  topic_arn = aws_sns_topic.alerts["sev2"].arn
  protocol  = "email"
  endpoint  = each.value
}

# --- Alarms --------------------------------------------------------------------------------------

locals {
  sev1 = aws_sns_topic.alerts["sev1"].arn
  sev2 = aws_sns_topic.alerts["sev2"].arn

}

# Per target group: 5xx ratio (SEV1), p99 latency (SEV2), unhealthy hosts (SEV2).
resource "aws_cloudwatch_metric_alarm" "tg_5xx_ratio" {
  for_each = local.target_groups

  alarm_name          = "${var.name_prefix}-tg-${each.key}-5xx-ratio"
  alarm_description   = "owner: ${var.alarm_owner} | severity: SEV1 | runbook: ${var.runbook_url}#tg-${each.key}-5xx-ratio | More than 2% of requests to the ${each.key} target group returned 5xx."
  comparison_operator = "GreaterThanThreshold"
  threshold           = 2
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sev1]
  ok_actions          = [local.sev1]

  metric_query {
    id          = "ratio"
    expression  = "IF(requests > 0, 100 * errors / requests, 0)"
    label       = "5xx ratio (%)"
    return_data = true
  }

  metric_query {
    id = "errors"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = var.alb_arn_suffix
        TargetGroup  = each.value
      }
    }
  }

  metric_query {
    id = "requests"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = var.alb_arn_suffix
        TargetGroup  = each.value
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "tg_p99_latency" {
  for_each = local.target_groups

  alarm_name          = "${var.name_prefix}-tg-${each.key}-p99-latency"
  alarm_description   = "owner: ${var.alarm_owner} | severity: SEV2 | runbook: ${var.runbook_url}#tg-${each.key}-p99-latency | p99 response time of the ${each.key} target group is above 1 second."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p99"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  threshold           = 1
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sev2]
  ok_actions          = [local.sev2]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = each.value
  }
}

resource "aws_cloudwatch_metric_alarm" "tg_unhealthy_hosts" {
  for_each = local.target_groups

  alarm_name          = "${var.name_prefix}-tg-${each.key}-unhealthy-hosts"
  alarm_description   = "owner: ${var.alarm_owner} | severity: SEV2 | runbook: ${var.runbook_url}#tg-${each.key}-unhealthy-hosts | The ${each.key} target group has had an unhealthy host for 5 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sev2]
  ok_actions          = [local.sev2]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = each.value
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_elb_5xx" {
  alarm_name          = "${var.name_prefix}-alb-elb-5xx"
  alarm_description   = "owner: ${var.alarm_owner} | severity: SEV1 | runbook: ${var.runbook_url}#alb-elb-5xx | The load balancer itself returned more than 10 5xx responses in a minute."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  statistic           = "Sum"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  threshold           = 10
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sev1]
  ok_actions          = [local.sev1]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name_prefix}-rds-cpu"
  alarm_description   = "owner: ${var.alarm_owner} | severity: SEV2 | runbook: ${var.runbook_url}#rds-cpu | Database CPU has been above 80% for 15 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sev2]
  ok_actions          = [local.sev2]

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  alarm_name          = "${var.name_prefix}-rds-free-storage"
  alarm_description   = "owner: ${var.alarm_owner} | severity: SEV2 | runbook: ${var.runbook_url}#rds-free-storage | Free database storage is below 10 GiB."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  comparison_operator = "LessThanThreshold"
  threshold           = 10 * 1024 * 1024 * 1024
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sev2]
  ok_actions          = [local.sev2]

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.name_prefix}-rds-connections"
  alarm_description   = "owner: ${var.alarm_owner} | severity: SEV2 | runbook: ${var.runbook_url}#rds-connections | Database connections have been above 80% of max_connections for 5 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Average"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0.8 * var.db_max_connections
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sev2]
  ok_actions          = [local.sev2]

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_freeable_memory" {
  alarm_name          = "${var.name_prefix}-rds-freeable-memory"
  alarm_description   = "owner: ${var.alarm_owner} | severity: SEV2 | runbook: ${var.runbook_url}#rds-freeable-memory | Freeable database memory has been below 256 MiB for 10 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Average"
  period              = 300
  comparison_operator = "LessThanThreshold"
  threshold           = 256 * 1024 * 1024
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sev2]
  ok_actions          = [local.sev2]

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }
}

# --- Cutover dashboard ---------------------------------------------------------------------------

locals {
  stacks = { legacy = var.target_groups.legacy, modern = var.target_groups.modern }

  tg_metric = {
    for stack, tg in local.stacks : stack => {
      requests  = ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", tg, { stat = "Sum", label = stack }]
      healthy   = ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", tg, { stat = "Maximum", label = "${stack} healthy" }]
      unhealthy = ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", tg, { stat = "Maximum", label = "${stack} unhealthy" }]
    }
  }

  widget_width = 12

  dashboard_widgets = concat(
    # Row 0: the weights in force, rendered at apply time.
    [{
      type   = "text"
      x      = 0
      y      = 0
      width  = 24
      height = 3
      properties = {
        markdown = join("\n", [
          "## Cutover weights",
          "",
          "| Traffic | legacy | modern |",
          "|---|---|---|",
          "| UI and track API | ${var.cutover.track.legacy} | ${var.cutover.track.modern} |",
          "| Everything else | ${var.cutover.default.legacy} | ${var.cutover.default.modern} |",
          "",
          "Rendered when the weights were last applied.",
        ])
      }
    }],
    # Row 1: request count per target group.
    [{
      type   = "metric"
      x      = 0
      y      = 3
      width  = 24
      height = 6
      properties = {
        title   = "Requests per target group"
        region  = local.region
        view    = "timeSeries"
        stacked = false
        period  = 60
        metrics = [local.tg_metric.legacy.requests, local.tg_metric.modern.requests]
      }
    }],
    # Row 2: 5xx ratio per target group, side by side.
    [for i, stack in ["legacy", "modern"] : {
      type   = "metric"
      x      = i * local.widget_width
      y      = 9
      width  = local.widget_width
      height = 6
      properties = {
        title  = "${stack}: 5xx ratio (%)"
        region = local.region
        view   = "timeSeries"
        period = 60
        metrics = [
          [{ expression = "IF(requests > 0, 100 * errors / requests, 0)", label = "5xx ratio", id = "ratio" }],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", local.stacks[stack], { id = "errors", visible = false, stat = "Sum" }],
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", local.stacks[stack], { id = "requests", visible = false, stat = "Sum" }],
        ]
      }
    }],
    # Row 3: p50, p95, p99 response time per target group.
    [for i, stack in ["legacy", "modern"] : {
      type   = "metric"
      x      = i * local.widget_width
      y      = 15
      width  = local.widget_width
      height = 6
      properties = {
        title  = "${stack}: response time"
        region = local.region
        view   = "timeSeries"
        period = 60
        metrics = [
          for p in ["p50", "p95", "p99"] :
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", local.stacks[stack], { stat = p, label = p }]
        ]
      }
    }],
    # Row 4: healthy and unhealthy hosts per target group.
    [for i, stack in ["legacy", "modern"] : {
      type   = "metric"
      x      = i * local.widget_width
      y      = 21
      width  = local.widget_width
      height = 6
      properties = {
        title   = "${stack}: hosts"
        region  = local.region
        view    = "timeSeries"
        period  = 60
        metrics = [local.tg_metric[stack].healthy, local.tg_metric[stack].unhealthy]
      }
    }],
    # Row 5: the database.
    [
      {
        type   = "metric"
        x      = 0
        y      = 27
        width  = 8
        height = 6
        properties = {
          title  = "RDS connections"
          region = local.region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.db_instance_id, { stat = "Average" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 27
        width  = 8
        height = 6
        properties = {
          title  = "RDS CPU (%)"
          region = local.region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_id, { stat = "Average" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 27
        width  = 8
        height = 6
        properties = {
          title  = "RDS read and write latency (s)"
          region = local.region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/RDS", "ReadLatency", "DBInstanceIdentifier", var.db_instance_id, { stat = "Average" }],
            ["AWS/RDS", "WriteLatency", "DBInstanceIdentifier", var.db_instance_id, { stat = "Average" }],
          ]
        }
      },
    ],
  )
}

resource "aws_cloudwatch_dashboard" "cutover" {
  dashboard_name = "${var.name_prefix}-cutover"
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}
