variable "aws_region" {
  description = "Region for the state bucket and all bootstrap resources."
  type        = string
  default     = "us-east-1"
}

variable "github_org" {
  description = "GitHub organization or user that owns the three repositories."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$", var.github_org))
    error_message = "github_org must be a valid GitHub user or organization name."
  }
}

variable "repositories" {
  description = "Repository names, without the organization."
  type = object({
    platform = string
    legacy   = string
    modern   = string
  })
  default = {
    platform = "shiptrack-platform"
    legacy   = "shiptrack-legacy"
    modern   = "shiptrack-modern"
  }
}

variable "environment" {
  description = "GitHub environment name and AWS environment tag. Roles for apply and deploy trust this environment."
  type        = string
  default     = "dev"
}

variable "branch" {
  description = "Branch whose workflows (drift, validation, release) may assume the plan and release roles."
  type        = string
  default     = "dev"
}

variable "seed_role_name" {
  description = "Name of the manually created role that runs bootstrap-apply.yml."
  type        = string
  default     = "shiptrack-bootstrap"
}

variable "owner" {
  description = "Value of the Owner tag."
  type        = string
  default     = "platform"
}

variable "cost_center" {
  description = "Value of the CostCenter tag."
  type        = string
  default     = "shiptrack"
}

variable "state_noncurrent_expiration_days" {
  description = "Days before noncurrent state object versions expire."
  type        = number
  default     = 90
}
