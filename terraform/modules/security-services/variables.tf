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

variable "config_recorder_name" {
  description = "Name of the AWS Config recorder. AWS allows one per region, so an account that already has one must keep its name (the dev account's is \"default\") and adopt it with an import block."
  type        = string
  default     = "shiptrack-recorder"
}

variable "config_delivery_channel_name" {
  description = "Name of the AWS Config delivery channel. As with the recorder, an existing one keeps its name."
  type        = string
  default     = "shiptrack-delivery"
}

variable "manage_access_analyzer" {
  description = "Create the account Access Analyzer. Turn it off when the account already has an account analyzer: AWS allows one per region."
  type        = bool
  default     = true
}

variable "inspector_timeout" {
  description = "How long to wait for Inspector to finish enabling EC2 and ECR scanning."
  type        = string
  default     = "20m"
}

variable "security_hub_timeout" {
  description = "How long to wait for a Security Hub standard to become ready, or to be removed."
  type        = string
  default     = "20m"
}
