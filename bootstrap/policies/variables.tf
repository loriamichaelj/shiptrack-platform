variable "account_id" {
  description = "AWS account ID."
  type        = string
}

variable "partition" {
  description = "AWS partition."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "github_org" {
  description = "GitHub organization or user."
  type        = string
}

variable "repositories" {
  description = "Repository names without the organization."
  type = object({
    platform = string
    legacy   = string
    modern   = string
  })
}

variable "environment" {
  description = "GitHub environment that apply and deploy jobs run in."
  type        = string
}

variable "branch" {
  description = "Branch that plan, drift, validation, and release workflows run on."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider created by hand."
  type        = string
}

variable "seed_role_name" {
  description = "Name of the manually created seed role."
  type        = string
}

variable "state_bucket_arn" {
  description = "ARN of the Terraform state bucket."
  type        = string
}

variable "state_kms_key_arn" {
  description = "ARN of the key that encrypts the state bucket."
  type        = string
}
