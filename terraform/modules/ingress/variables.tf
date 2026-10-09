variable "name_prefix" {
  description = "Prefix of resource names, as in <name_prefix>-alb."
  type        = string
  default     = "shiptrack"
}

variable "environment" {
  description = "Environment name; it is part of the test-routing token's secret name."
  type        = string
  default     = "dev"
}

variable "vpc_id" {
  description = "ID of the VPC."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the ALB."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "ID of the shiptrack-alb security group."
  type        = string
}

variable "alb_logs_bucket_name" {
  description = "Name of the bucket that receives the ALB access logs."
  type        = string
}

variable "secrets_key_arn" {
  description = "ARN of the secrets key that encrypts the test-routing token."
  type        = string
}

variable "cutover" {
  description = "ALB traffic weights. Changing this IS the cutover. Each change requires a PR."
  type = object({
    track   = object({ legacy = number, modern = number })
    default = object({ legacy = number, modern = number })
  })
  default = {
    track   = { legacy = 100, modern = 0 }
    default = { legacy = 100, modern = 0 }
  }

  validation {
    condition = alltrue([
      for w in [
        var.cutover.track.legacy, var.cutover.track.modern,
        var.cutover.default.legacy, var.cutover.default.modern,
      ] : w >= 0 && w <= 999
    ])
    error_message = "Every cutover weight must be between 0 and 999."
  }

  validation {
    condition = alltrue([
      var.cutover.track.legacy + var.cutover.track.modern > 0,
      var.cutover.default.legacy + var.cutover.default.modern > 0,
    ])
    error_message = "Each cutover map needs a total weight above 0, or the ALB has nowhere to send traffic."
  }
}

variable "ui_stickiness_seconds" {
  description = "How long a browser stays with one stack for the UI rule, so the page and its assets come from the same build."
  type        = number
  default     = 3600

  validation {
    condition     = var.ui_stickiness_seconds >= 1 && var.ui_stickiness_seconds <= 604800
    error_message = "ui_stickiness_seconds must be between 1 second and 7 days."
  }
}

variable "domain_name" {
  description = "Custom domain for the ALB. When set, the ALB gets an ACM certificate, an HTTPS listener, and an HTTP redirect; when null it serves plain HTTP on port 80 (risk R-01)."
  type        = string
  default     = null
}

variable "hosted_zone_name" {
  description = "Name of the existing Route 53 hosted zone that holds domain_name. Defaults to domain_name."
  type        = string
  default     = null
}

variable "ssl_policy" {
  description = "TLS policy of the HTTPS listener (TLS 1.3/1.2 with hybrid post-quantum key exchange)."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"
}

variable "enable_waf" {
  description = "Attach an AWS WAF web ACL: the common and known-bad-inputs managed rule sets and a rate limit."
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Requests per five minutes from one IP address before the WAF blocks it."
  type        = number
  default     = 2000
}
