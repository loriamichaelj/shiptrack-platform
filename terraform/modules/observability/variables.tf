variable "name_prefix" {
  description = "Prefix of resource names, as in <name_prefix>-alerts-sev1."
  type        = string
  default     = "shiptrack"
}

variable "logs_key_arn" {
  description = "ARN of the logs key that encrypts the alert topics. CloudWatch alarms cannot publish to topics encrypted with the AWS-managed key."
  type        = string
}

variable "alert_emails" {
  description = "Comma-separated email addresses for both alert topics. Each recipient must confirm the subscription by hand. Empty means no subscriptions."
  type        = string
  default     = ""
}

variable "runbook_url" {
  description = "URL of the runbook page; every alarm description links to it with the alarm name as the anchor."
  type        = string
}

variable "alarm_owner" {
  description = "Owner named in every alarm description."
  type        = string
  default     = "platform"
}

variable "alb_arn_suffix" {
  description = "ARN suffix of the ALB, for CloudWatch dimensions."
  type        = string
}

variable "target_groups" {
  description = "ARN suffixes of the target groups, by stack."
  type = object({
    legacy = string
    modern = string
  })
}

variable "db_instance_id" {
  description = "Identifier of the RDS instance."
  type        = string
}

variable "db_max_connections" {
  description = "Expected max_connections; the connections alarm fires at 80% of it."
  type        = number
}

variable "cutover" {
  description = "The ALB weights, shown on the cutover dashboard."
  type = object({
    track   = object({ legacy = number, modern = number })
    default = object({ legacy = number, modern = number })
  })
}
