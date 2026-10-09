# Published to the SSM contract by modules/contract (P5).

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "CIDR of the VPC."
  value       = module.network.vpc_cidr
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = module.network.public_subnet_ids
}

output "private_app_subnet_ids" {
  description = "Private-app subnet IDs."
  value       = module.network.private_app_subnet_ids
}

output "private_data_subnet_ids" {
  description = "Private-data subnet IDs."
  value       = module.network.private_data_subnet_ids
}

output "sg_alb_id" {
  description = "ID of the ALB security group."
  value       = module.network.sg_alb_id
}

output "sg_db_client_id" {
  description = "ID of the database-client security group."
  value       = module.network.sg_db_client_id
}

output "sg_db_id" {
  description = "ID of the database security group."
  value       = module.network.sg_db_id
}

output "kms_data_key_arn" {
  description = "ARN of the data key."
  value       = module.kms.data_key_arn
}

output "kms_secrets_key_arn" {
  description = "ARN of the secrets key."
  value       = module.kms.secrets_key_arn
}

output "kms_logs_key_arn" {
  description = "ARN of the logs key."
  value       = module.kms.logs_key_arn
}

output "rds_endpoint" {
  description = "Address of the RDS instance."
  value       = module.database.endpoint
}

output "rds_port" {
  description = "Port of the RDS instance."
  value       = module.database.port
}

output "db_name" {
  description = "Name of the application database."
  value       = module.database.db_name
}

output "db_max_connections" {
  description = "Expected max_connections."
  value       = module.database.max_connections
}

output "db_app_secret_arn" {
  description = "ARN of the application credentials secret."
  value       = module.database.app_secret_arn
}

output "db_migrator_secret_arn" {
  description = "ARN of the migrator credentials secret."
  value       = module.database.migrator_secret_arn
}

output "db_master_secret_arn" {
  description = "ARN of the RDS-managed master secret."
  value       = module.database.master_secret_arn
}
