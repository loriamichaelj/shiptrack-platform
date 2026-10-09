# Offline: the AWS provider is mocked, so nothing contacts AWS. The random provider is real and makes
# no network calls.
mock_provider "aws" {
  mock_resource "aws_lb" {
    defaults = {
      arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/shiptrack-alb/0123456789abcdef"
      dns_name = "alb.mock.test"
      zone_id  = "Z0000000000000"
    }
  }
  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/shiptrack-alb/0123456789abcdef/0123456789abcdef"
    }
  }
}

override_resource {
  target = aws_lb_target_group.legacy
  values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/legacy/0123456789abcdef" }
}

override_resource {
  target = aws_lb_target_group.modern
  values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/modern/0123456789abcdef" }
}

variables {
  vpc_id                = "vpc-mock"
  public_subnet_ids     = ["subnet-a", "subnet-b", "subnet-c"]
  alb_security_group_id = "sg-mock"
  alb_logs_bucket_name  = "shiptrack-alb-logs-mock"
  secrets_key_arn       = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000b"
}

run "alb_follows_the_design" {
  command = apply

  assert {
    condition = alltrue([
      aws_lb.this.name == "shiptrack-alb",
      !aws_lb.this.internal,
      aws_lb.this.enable_deletion_protection,
      aws_lb.this.drop_invalid_header_fields,
      aws_lb.this.desync_mitigation_mode == "defensive",
      aws_lb.this.idle_timeout == 60,
      one(aws_lb.this.access_logs).enabled,
    ])
    error_message = "The ALB must match design §6.6."
  }
}

run "target_groups_follow_the_design" {
  command = apply

  assert {
    condition = alltrue([
      aws_lb_target_group.legacy.target_type == "instance",
      aws_lb_target_group.legacy.port == 80,
      one(aws_lb_target_group.legacy.health_check).path == "/",
      one(aws_lb_target_group.legacy.health_check).interval == 30,
      one(aws_lb_target_group.legacy.health_check).healthy_threshold == 5,
      one(aws_lb_target_group.legacy.health_check).unhealthy_threshold == 2,
      aws_lb_target_group.legacy.deregistration_delay == "300",
      one(aws_lb_target_group.legacy.stickiness).type == "lb_cookie",
      one(aws_lb_target_group.legacy.stickiness).cookie_duration == 86400,
      one(aws_lb_target_group.legacy.stickiness).enabled,
    ])
    error_message = "The legacy target group must match design §6.6, including its intentional anti-patterns."
  }

  assert {
    condition = alltrue([
      aws_lb_target_group.modern.target_type == "ip",
      aws_lb_target_group.modern.port == 8000,
      one(aws_lb_target_group.modern.health_check).path == "/readyz",
      one(aws_lb_target_group.modern.health_check).interval == 10,
      one(aws_lb_target_group.modern.health_check).healthy_threshold == 2,
      aws_lb_target_group.modern.deregistration_delay == "30",
      aws_lb_target_group.modern.slow_start == 30,
      length(aws_lb_target_group.modern.stickiness) == 0 || !one(aws_lb_target_group.modern.stickiness).enabled,
    ])
    error_message = "The modern target group must match design §6.6."
  }
}

run "four_rules_and_a_weighted_default" {
  command = apply

  assert {
    condition = [
      aws_lb_listener_rule.test_legacy.priority,
      aws_lb_listener_rule.test_modern.priority,
      aws_lb_listener_rule.ui.priority,
      aws_lb_listener_rule.track.priority,
    ] == [10, 20, 90, 100]
    error_message = "The rules must have priorities 10, 20, 90, and 100."
  }

  assert {
    condition = alltrue([
      { for t in one(one(aws_lb_listener.http.default_action).forward).target_group : t.arn => t.weight } == { "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/legacy/0123456789abcdef" = 100, "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/modern/0123456789abcdef" = 0 },
      length(one(one(aws_lb_listener.http.default_action).forward).target_group) == 2,
    ])
    error_message = "Without a domain, the HTTP listener's default action is a weighted forward."
  }

  assert {
    condition     = length(aws_lb_listener.https) == 0
    error_message = "No HTTPS listener without a domain."
  }
}

run "header_rules_need_the_target_and_the_token" {
  command = apply

  assert {
    condition = alltrue([
      length(aws_lb_listener_rule.test_legacy.condition) == 2,
      length(aws_lb_listener_rule.test_modern.condition) == 2,
      anytrue([for c in aws_lb_listener_rule.test_legacy.condition : length(c.http_header) == 1 && one(c.http_header).http_header_name == "X-ShipTrack-Test-Token"]),
      anytrue([for c in aws_lb_listener_rule.test_legacy.condition : length(c.http_header) == 1 && one(c.http_header).http_header_name == "X-ShipTrack-Target" && one(c.http_header).values == toset(["legacy"])]),
      anytrue([for c in aws_lb_listener_rule.test_modern.condition : length(c.http_header) == 1 && one(c.http_header).http_header_name == "X-ShipTrack-Target" && one(c.http_header).values == toset(["modern"])]),
    ])
    error_message = "Each header rule needs both the target header and the token header."
  }

  assert {
    condition     = length(random_password.test_token.result) == 32 && can(regex("^[A-Za-z0-9]{32}$", random_password.test_token.result))
    error_message = "The token is 32 alphanumeric characters."
  }

  assert {
    condition     = aws_secretsmanager_secret.test_token.name == "shiptrack/dev/test-routing-token"
    error_message = "The token's secret name is the one the plan role may read."
  }
}

# AWS refuses a weighted forward to a target group with target stickiness unless the forward also
# has group stickiness (the legacy group has it, AP-05). The UI keeps the long duration; the API and
# default actions use the shortest, so clients re-roll between stacks almost every request.
run "every_weighted_forward_has_group_stickiness" {
  command = apply

  assert {
    condition = alltrue([
      one(one(one(aws_lb_listener_rule.ui.action).forward).stickiness).enabled,
      one(one(one(aws_lb_listener_rule.ui.action).forward).stickiness).duration == 3600,
      one(one(one(aws_lb_listener_rule.track.action).forward).stickiness).enabled,
      one(one(one(aws_lb_listener_rule.track.action).forward).stickiness).duration == 1,
      one(one(one(aws_lb_listener.http.default_action).forward).stickiness).enabled,
      one(one(one(aws_lb_listener.http.default_action).forward).stickiness).duration == 1,
    ])
    error_message = "Each weighted forward needs group stickiness: 3600 s for the UI, 1 s for the API and default."
  }

  assert {
    condition = alltrue([
      for r in [aws_lb_listener_rule.test_legacy, aws_lb_listener_rule.test_modern] :
      length(one(r.action).forward) == 0
    ])
    error_message = "The header rules forward to one target group and need no group stickiness."
  }

  assert {
    condition = alltrue([
      one([for c in aws_lb_listener_rule.ui.condition : c.path_pattern if length(c.path_pattern) == 1])[0].values == toset(["/ui", "/ui/*"]),
      one([for c in aws_lb_listener_rule.track.condition : c.path_pattern if length(c.path_pattern) == 1])[0].values == toset(["/api/v1/track/*"]),
    ])
    error_message = "Rule paths must be /ui, /ui/* and /api/v1/track/*."
  }
}

# The cutover: weights move in the rules and the default action, and nothing else changes.
run "changing_the_weights_moves_only_the_weights" {
  command = plan

  variables {
    cutover = {
      track   = { legacy = 90, modern = 10 }
      default = { legacy = 100, modern = 0 }
    }
  }

  assert {
    condition = alltrue([
      { for t in one(one(aws_lb_listener_rule.track.action).forward).target_group : t.arn => t.weight } == { "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/legacy/0123456789abcdef" = 90, "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/modern/0123456789abcdef" = 10 },
      { for t in one(one(aws_lb_listener_rule.ui.action).forward).target_group : t.arn => t.weight } == { "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/legacy/0123456789abcdef" = 90, "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/modern/0123456789abcdef" = 10 },
    ])
    error_message = "The UI and track rules share cutover.track."
  }

  assert {
    condition = alltrue([
      { for t in one(one(aws_lb_listener.http.default_action).forward).target_group : t.arn => t.weight } == { "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/legacy/0123456789abcdef" = 100, "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/modern/0123456789abcdef" = 0 },
      aws_lb.this.enable_deletion_protection,
      one(aws_lb_target_group.legacy.health_check).path == "/",
      aws_lb_listener_rule.test_legacy.priority == 10,
    ])
    error_message = "Moving the track weights must not touch the default action, the ALB, or the header rules."
  }
}

run "default_weights_move_the_default_action" {
  command = plan

  variables {
    cutover = {
      track   = { legacy = 100, modern = 0 }
      default = { legacy = 0, modern = 100 }
    }
  }

  assert {
    condition     = { for t in one(one(aws_lb_listener.http.default_action).forward).target_group : t.arn => t.weight } == { "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/legacy/0123456789abcdef" = 0, "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/modern/0123456789abcdef" = 100 }
    error_message = "cutover.default drives the default action."
  }

  assert {
    condition     = { for t in one(one(aws_lb_listener_rule.track.action).forward).target_group : t.arn => t.weight } == { "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/legacy/0123456789abcdef" = 100, "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/modern/0123456789abcdef" = 0 }
    error_message = "cutover.default must not change the track rules."
  }
}

run "rejects_bad_weights" {
  command = plan

  variables {
    cutover = {
      track   = { legacy = 0, modern = 0 }
      default = { legacy = 100, modern = 0 }
    }
  }

  expect_failures = [var.cutover]
}

run "rejects_an_oversize_weight" {
  command = plan

  variables {
    cutover = {
      track   = { legacy = 1000, modern = 0 }
      default = { legacy = 100, modern = 0 }
    }
  }

  expect_failures = [var.cutover]
}

run "the_https_default_action_also_has_group_stickiness" {
  command = plan

  variables {
    domain_name = "shiptrack.example.com"
  }

  override_data {
    target = data.aws_route53_zone.this[0]
    values = { zone_id = "Z0000000000001" }
  }

  assert {
    condition = alltrue([
      one(one(one(aws_lb_listener.https[0].default_action).forward).stickiness).enabled,
      one(one(one(aws_lb_listener.https[0].default_action).forward).stickiness).duration == 1,
    ])
    error_message = "The HTTPS default action is a weighted forward and needs group stickiness."
  }
}

run "a_domain_adds_tls_and_a_redirect" {
  command = plan

  variables {
    domain_name = "shiptrack.example.com"
  }

  override_data {
    target = data.aws_route53_zone.this[0]
    values = { zone_id = "Z0000000000001" }
  }

  assert {
    condition = alltrue([
      length(aws_lb_listener.https) == 1,
      aws_lb_listener.https[0].port == 443,
      aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09",
      one(aws_lb_listener.http.default_action).type == "redirect",
      one(one(aws_lb_listener.http.default_action).redirect).status_code == "HTTP_301",
    ])
    error_message = "A domain adds HTTPS with the design's TLS policy and redirects HTTP."
  }
}

run "waf_is_off_by_default_and_optional" {
  command = plan

  assert {
    condition     = length(aws_wafv2_web_acl.this) == 0
    error_message = "The WAF is off by default."
  }
}

run "waf_when_enabled" {
  command = plan

  variables {
    enable_waf = true
  }

  assert {
    condition = alltrue([
      length(aws_wafv2_web_acl.this) == 1,
      length(aws_wafv2_web_acl.this[0].rule) == 3,
    ])
    error_message = "The WAF has the common set, the known-bad-inputs set, and a rate limit."
  }
}

run "an_empty_domain_means_no_tls" {
  command = plan

  variables {
    domain_name      = ""
    hosted_zone_name = ""
  }

  assert {
    condition = alltrue([
      length(aws_lb_listener.https) == 0,
      length(aws_acm_certificate.this) == 0,
      one(aws_lb_listener.http.default_action).type == "forward",
    ])
    error_message = "An empty domain_name (an unset repository variable) must behave like null."
  }
}
