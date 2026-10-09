# The ALB, its listeners and target groups, and the cutover routing rules (design §6.6). Platform
# never registers targets: legacy instances register through the ASG, modern pods through a
# TargetGroupBinding.

locals {
  alb_name = "${var.name_prefix}-alb"
  # A workflow passes an empty string when the DOMAIN_NAME repository variable is not set.
  tls       = var.domain_name != null && try(length(var.domain_name) > 0, false)
  zone_name = coalesce(var.hosted_zone_name, var.domain_name, "unused")

  # Every routing rule attaches to the listener that serves traffic.
  serving_listener_arn = local.tls ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
}

# --- Load balancer -------------------------------------------------------------------------------

# The ALB is the public entry point of the application (design §6.6) (AWS-0053).
#trivy:ignore:AWS-0053
resource "aws_lb" "this" {
  #checkov:skip=CKV2_AWS_28: the WAF is the optional enable_waf toggle, off by default for cost
  #checkov:skip=CKV2_AWS_20: without a custom domain there is no HTTPS to redirect to (risk R-01)
  #checkov:skip=CKV2_AWS_76: the WAF is optional and off by default; the Log4j rule set is attached when enable_waf is on
  name                       = local.alb_name
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = var.public_subnet_ids
  security_groups            = [var.alb_security_group_id]
  idle_timeout               = 60
  enable_deletion_protection = true
  drop_invalid_header_fields = true
  desync_mitigation_mode     = "defensive"

  access_logs {
    bucket  = var.alb_logs_bucket_name
    prefix  = "alb"
    enabled = true
  }
}

# --- Target groups -------------------------------------------------------------------------------

resource "aws_lb_target_group" "legacy" {
  #checkov:skip=CKV_AWS_378: traffic from the ALB to targets stays inside the VPC; TLS ends at the ALB
  name        = "${var.name_prefix}-tg-legacy"
  target_type = "instance"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id

  deregistration_delay = 300
  slow_start           = 0

  # LEGACY AP-07: the health check is a shallow "/" that does not touch the database. Intentional.
  health_check {
    path                = "/"
    interval            = 30
    healthy_threshold   = 5
    unhealthy_threshold = 2
    timeout             = 5
    matcher             = "200"
  }

  # LEGACY AP-05: load-balancer cookie stickiness for a day. Intentional.
  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }
}

resource "aws_lb_target_group" "modern" {
  #checkov:skip=CKV_AWS_378: traffic from the ALB to targets stays inside the VPC; TLS ends at the ALB
  name        = "${var.name_prefix}-tg-modern"
  target_type = "ip"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id

  deregistration_delay = 30
  slow_start           = 30

  health_check {
    path                = "/readyz"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    matcher             = "200"
  }
}

# --- Test-routing token --------------------------------------------------------------------------
# A low-sensitivity selector that lets CI address one stack directly. It appears in the listener
# rules and so in state (risk R-04). Rotate it by replacing the random_password resource.

resource "random_password" "test_token" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "test_token" {
  #checkov:skip=CKV2_AWS_57: the token is rotated by replacing the random_password resource (design §6.6)
  name       = "shiptrack/${var.environment}/test-routing-token"
  kms_key_id = var.secrets_key_arn
}

resource "aws_secretsmanager_secret_version" "test_token" {
  secret_id     = aws_secretsmanager_secret.test_token.id
  secret_string = random_password.test_token.result
}

# --- TLS (only with a custom domain) -------------------------------------------------------------

data "aws_route53_zone" "this" {
  count = local.tls ? 1 : 0

  name         = local.zone_name
  private_zone = false
}

resource "aws_acm_certificate" "this" {
  count = local.tls ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# One domain, so one validation record. The key is the configured name, which is known at plan
# time; the record's values come from the certificate at apply time.
resource "aws_route53_record" "validation" {
  for_each = local.tls ? toset([var.domain_name]) : toset([])

  zone_id         = data.aws_route53_zone.this[0].zone_id
  name            = one([for o in aws_acm_certificate.this[0].domain_validation_options : o.resource_record_name if o.domain_name == each.key])
  type            = one([for o in aws_acm_certificate.this[0].domain_validation_options : o.resource_record_type if o.domain_name == each.key])
  records         = [one([for o in aws_acm_certificate.this[0].domain_validation_options : o.resource_record_value if o.domain_name == each.key])]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = local.tls ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

resource "aws_route53_record" "alb" {
  count = local.tls ? 1 : 0

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

# --- Listeners -----------------------------------------------------------------------------------

# Without a custom domain the ALB serves plain HTTP (risk R-01); with one, this listener only redirects (AWS-0054).
#trivy:ignore:AWS-0054
resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2: without a custom domain the ALB serves plain HTTP (risk R-01); with one, this listener only redirects
  #checkov:skip=CKV_AWS_103: no TLS listener exists without a custom domain (risk R-01)
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.tls ? [1] : []

    content {
      type = "redirect"

      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.tls ? [] : [1]

    content {
      type = "forward"

      forward {
        target_group {
          arn    = aws_lb_target_group.legacy.arn
          weight = var.cutover.default.legacy
        }
        target_group {
          arn    = aws_lb_target_group.modern.arn
          weight = var.cutover.default.modern
        }
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.tls ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = aws_acm_certificate_validation.this[0].certificate_arn

  default_action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.legacy.arn
        weight = var.cutover.default.legacy
      }
      target_group {
        arn    = aws_lb_target_group.modern.arn
        weight = var.cutover.default.modern
      }
    }
  }
}

# --- Routing rules (lower priority numbers are evaluated first) ----------------------------------

# Header rules let the team and CI test one stack before it receives real traffic.
resource "aws_lb_listener_rule" "test_legacy" {
  listener_arn = local.serving_listener_arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.legacy.arn
  }

  condition {
    http_header {
      http_header_name = "X-ShipTrack-Target"
      values           = ["legacy"]
    }
  }

  condition {
    http_header {
      http_header_name = "X-ShipTrack-Test-Token"
      values           = [random_password.test_token.result]
    }
  }
}

resource "aws_lb_listener_rule" "test_modern" {
  listener_arn = local.serving_listener_arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.modern.arn
  }

  condition {
    http_header {
      http_header_name = "X-ShipTrack-Target"
      values           = ["modern"]
    }
  }

  condition {
    http_header {
      http_header_name = "X-ShipTrack-Test-Token"
      values           = [random_password.test_token.result]
    }
  }
}

# The UI sticks to one stack: the HTML and its hashed assets load in separate requests, and a
# mixed pair of builds would break the page (risk R-08).
resource "aws_lb_listener_rule" "ui" {
  listener_arn = local.serving_listener_arn
  priority     = 90

  action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.legacy.arn
        weight = var.cutover.track.legacy
      }
      target_group {
        arn    = aws_lb_target_group.modern.arn
        weight = var.cutover.track.modern
      }

      stickiness {
        enabled  = true
        duration = var.ui_stickiness_seconds
      }
    }
  }

  condition {
    path_pattern {
      values = ["/ui", "/ui/*"]
    }
  }

  condition {
    http_request_method {
      values = ["GET"]
    }
  }
}

# The API is stateless on the modern side, so there is no stickiness here: it would skew the
# canary statistics.
resource "aws_lb_listener_rule" "track" {
  listener_arn = local.serving_listener_arn
  priority     = 100

  action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.legacy.arn
        weight = var.cutover.track.legacy
      }
      target_group {
        arn    = aws_lb_target_group.modern.arn
        weight = var.cutover.track.modern
      }
    }
  }

  condition {
    path_pattern {
      values = ["/api/v1/track/*"]
    }
  }

  condition {
    http_request_method {
      values = ["GET"]
    }
  }
}

# --- WAF (optional) ------------------------------------------------------------------------------

resource "aws_wafv2_web_acl" "this" {
  #checkov:skip=CKV2_AWS_31: WAF request logging is not part of the design
  count = var.enable_waf ? 1 : 0

  name  = "${var.name_prefix}-alb"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "common"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-waf-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "known-bad-inputs"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-waf-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-limit"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-waf-rate"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "this" {
  count = var.enable_waf ? 1 : 0

  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}
