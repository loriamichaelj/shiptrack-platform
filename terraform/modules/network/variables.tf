variable "name_prefix" {
  description = "Prefix of resource names, as in <name_prefix>-alb."
  type        = string
  default     = "shiptrack"
}

variable "role_prefix" {
  description = "Prefix of IAM role names (<owner>-<environment>-<project>)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR of the VPC. It must be at least a /16 so the subnet plan below fits."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) <= 16
    error_message = "vpc_cidr must be a valid CIDR no smaller than a /16."
  }
}

variable "nat_gateway_mode" {
  description = "single: one NAT gateway for every AZ (cheaper; an AZ outage takes out egress, risk R-03). per_az: one per AZ."
  type        = string
  default     = "single"

  validation {
    condition     = contains(["single", "per_az"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be single or per_az."
  }
}

variable "enable_interface_endpoints" {
  description = "Create the interface VPC endpoints (billed per AZ-hour per endpoint; optimization item O-P1)."
  type        = bool
  default     = false
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_tls" {
  description = "Also open port 443 on the ALB security group (needs a custom domain, risk R-01)."
  type        = bool
  default     = false
}

variable "logs_kms_key_arn" {
  description = "ARN of the logs key that encrypts the flow-log group."
  type        = string
}

variable "flow_log_retention_days" {
  description = "Days the VPC flow logs are kept."
  type        = number
  default     = 14
}

variable "karpenter_discovery_tag" {
  description = "Value of the karpenter.sh/discovery tag on the private-app subnets."
  type        = string
  default     = "shiptrack"
}
