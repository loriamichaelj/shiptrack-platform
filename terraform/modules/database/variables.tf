variable "name_prefix" {
  description = "Prefix of resource names, as in <name_prefix>-db."
  type        = string
  default     = "shiptrack"
}

variable "role_prefix" {
  description = "Prefix of IAM role names (<owner>-<environment>-<project>)."
  type        = string
}

variable "environment" {
  description = "Environment name; it is part of the secret names (shiptrack/<environment>/db/...)."
  type        = string
  default     = "dev"
}

variable "subnet_ids" {
  description = "Private-data subnet IDs for the DB subnet group."
  type        = list(string)
}

variable "security_group_id" {
  description = "ID of the shiptrack-db security group."
  type        = string
}

variable "data_key_arn" {
  description = "ARN of the data key (storage and Performance Insights)."
  type        = string
}

variable "secrets_key_arn" {
  description = "ARN of the secrets key (the master and application secrets)."
  type        = string
}

variable "logs_key_arn" {
  description = "ARN of the logs key (the exported log groups)."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL 17 minor version. [VERIFY against `aws rds describe-db-engine-versions --engine postgres --engine-version 17`.]"
  type        = string
  default     = "17.10"

  validation {
    condition     = can(regex("^17\\.[0-9]+$", var.engine_version))
    error_message = "engine_version must be a PostgreSQL 17 minor version such as 17.10."
  }
}

variable "parameter_group_family" {
  description = "Parameter group family; it must match the engine's major version."
  type        = string
  default     = "postgres17"
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.medium"
}

variable "allocated_storage" {
  description = "Initial gp3 storage in GiB."
  type        = number
  default     = 50
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB."
  type        = number
  default     = 200
}

variable "multi_az" {
  description = "Run a standby in a second AZ (cost; risk R-05)."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Days automated backups are kept."
  type        = number
  default     = 7
}

variable "backup_window" {
  description = "Daily backup window (UTC). It must not overlap the maintenance window."
  type        = string
  default     = "05:00-06:00"
}

variable "maintenance_window" {
  description = "Weekly maintenance window (UTC)."
  type        = string
  default     = "sun:07:00-sun:08:00"
}

variable "log_retention_days" {
  description = "Days the exported PostgreSQL logs are kept."
  type        = number
  default     = 14
}

variable "db_secret_version" {
  description = "Bump to rotate the application and migrator passwords: a new value is written to Secrets Manager only when this changes."
  type        = number
  default     = 1
}

variable "max_connections" {
  description = "Expected max_connections, published for consumers' pool budgets. [VERIFY with SHOW max_connections.]"
  type        = number
  default     = 400
}
