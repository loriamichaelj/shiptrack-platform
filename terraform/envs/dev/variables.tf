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
