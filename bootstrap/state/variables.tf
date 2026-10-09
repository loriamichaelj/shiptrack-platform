variable "bucket_name" {
  description = "Name of the Terraform state bucket."
  type        = string
}

variable "account_id" {
  description = "AWS account ID, used in the key policy."
  type        = string
}

variable "partition" {
  description = "AWS partition."
  type        = string
}

variable "noncurrent_expiration_days" {
  description = "Days before noncurrent object versions expire."
  type        = number
}
