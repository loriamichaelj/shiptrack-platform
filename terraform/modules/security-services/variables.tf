variable "name_prefix" {
  description = "Prefix of resource names."
  type        = string
  default     = "shiptrack"
}

variable "role_prefix" {
  description = "Prefix of IAM role names (<owner>-<environment>-<project>)."
  type        = string
}

variable "trail_name" {
  description = "Name of the CloudTrail trail. The CloudTrail bucket policy (modules/storage) allows exactly this name."
  type        = string
  default     = "shiptrack-trail"
}

variable "cloudtrail_bucket_name" {
  description = "Name of the bucket that receives CloudTrail and AWS Config deliveries."
  type        = string
}

variable "pod_bucket_arn" {
  description = "ARN of the proof-of-delivery bucket, for the optional S3 data events."
  type        = string
}

variable "logs_key_arn" {
  description = "ARN of the logs key that encrypts the trail and the Config deliveries."
  type        = string
}

variable "sns_sev2_arn" {
  description = "ARN of the SEV2 alert topic, which receives the high-severity Security Hub findings."
  type        = string
}

variable "enable_pod_data_events" {
  description = "Record S3 data events for the POD bucket (billed per event)."
  type        = bool
  default     = false
}

variable "enable_guardduty_runtime" {
  description = "Enable GuardDuty Runtime Monitoring for EKS with automated agent management (billed per vCPU)."
  type        = bool
  default     = true
}
