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
