variable "aws_region" {
  description = "Region of every resource in this environment."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name; it is also the Environment tag."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag. The workflows supply the GitHub repository owner (TF_VAR_owner)."
  type        = string

  validation {
    condition     = length(var.owner) > 0
    error_message = "owner must not be empty."
  }
}

variable "cost_center" {
  description = "CostCenter tag."
  type        = string
}

variable "role_prefix" {
  description = "Prefix of every IAM role and policy name: <owner>-<environment>-<project>. The workflows supply it from the ROLE_PREFIX repository variable (TF_VAR_role_prefix)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,38}[a-z0-9]$", var.role_prefix))
    error_message = "role_prefix must be 2 to 40 characters: lowercase letters, digits, and hyphens."
  }
}

variable "vpc_cidr" {
  description = "CIDR of the VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "nat_gateway_mode" {
  description = "single or per_az (risk R-03)."
  type        = string
  default     = "single"
}

variable "enable_interface_endpoints" {
  description = "Create the interface VPC endpoints (optimization item O-P1)."
  type        = bool
  default     = false
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_tls" {
  description = "Open port 443 on the ALB security group."
  type        = bool
  default     = false
}

variable "db_engine_version" {
  description = "PostgreSQL 17 minor version. [VERIFY against the engine versions RDS offers.]"
  type        = string
  default     = "17.10"
}

variable "db_instance_class" {
  description = "RDS instance class. db.t3.medium because AWS reported no db.t4g.medium capacity for gp3 in the account's AZs (ADR-0016)."
  type        = string
  default     = "db.t3.medium"
}

variable "db_allocated_storage" {
  description = "Initial database storage in GiB."
  type        = number
  default     = 50
}

variable "db_max_allocated_storage" {
  description = "Database storage autoscaling ceiling in GiB."
  type        = number
  default     = 200
}

variable "db_multi_az" {
  description = "Run a standby in a second AZ (cost; risk R-05)."
  type        = bool
  default     = false
}

variable "db_backup_window" {
  description = "Daily backup window (UTC)."
  type        = string
  default     = "05:00-06:00"
}

variable "db_maintenance_window" {
  description = "Weekly maintenance window (UTC)."
  type        = string
  default     = "sun:07:00-sun:08:00"
}

variable "db_secret_version" {
  description = "Bump to rotate the application and migrator passwords."
  type        = number
  default     = 1
}

variable "db_max_connections" {
  description = "Expected max_connections, published for consumers' pool budgets. [VERIFY with SHOW max_connections.]"
  type        = number
  default     = 400
}

variable "pod_retention_days" {
  description = "Days a proof-of-delivery document is kept (2555 is about seven years)."
  type        = number
  default     = 2555
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
}

variable "ui_stickiness_seconds" {
  description = "How long a browser stays with one stack for the UI rule."
  type        = number
  default     = 3600
}

variable "domain_name" {
  description = "Custom domain for the ALB. Without one the ALB serves plain HTTP (risk R-01). Supplied by the workflows from the DOMAIN_NAME repository variable when it is set."
  type        = string
  default     = null
}

variable "hosted_zone_name" {
  description = "Existing Route 53 hosted zone that holds domain_name; defaults to domain_name."
  type        = string
  default     = null
}

variable "enable_waf" {
  description = "Attach the AWS WAF web ACL to the ALB."
  type        = bool
  default     = false
}

variable "alert_emails" {
  description = "Comma-separated addresses for the SEV1 and SEV2 alert topics. The workflows supply them from the ALERT_EMAILS repository variable; each recipient must confirm by hand."
  type        = string
  default     = ""
}

variable "enable_pod_data_events" {
  description = "Record S3 data events for the POD bucket in CloudTrail (billed per event)."
  type        = bool
  default     = false
}

variable "enable_guardduty_runtime" {
  description = "Enable GuardDuty Runtime Monitoring for EKS with automated agent management (billed per vCPU)."
  type        = bool
  default     = true
}
