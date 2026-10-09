variable "name_prefix" {
  description = "Prefix of bucket names, as in <name_prefix>-pod-<account>-<region>."
  type        = string
  default     = "shiptrack"
}

variable "data_key_arn" {
  description = "ARN of the data key that encrypts the POD bucket."
  type        = string
}

variable "logs_key_arn" {
  description = "ARN of the logs key that encrypts the CloudTrail bucket."
  type        = string
}

variable "pod_retention_days" {
  description = "Days a proof-of-delivery document is kept (2555 is about seven years)."
  type        = number
  default     = 2555

  validation {
    condition     = var.pod_retention_days > 90
    error_message = "pod_retention_days must be longer than the 90 days before documents move to Glacier Instant Retrieval."
  }
}

variable "trail_name" {
  description = "Name of the CloudTrail trail that writes to the CloudTrail bucket (created by modules/security-services)."
  type        = string
  default     = "shiptrack-trail"
}
