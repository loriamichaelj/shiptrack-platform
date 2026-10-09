output "endpoint" {
  description = "Address of the RDS instance (no port)."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Port of the RDS instance."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Name of the application database, created by db/bootstrap.sql."
  value       = "shiptrack"
}

output "max_connections" {
  description = "Expected max_connections, for consumers' pool budgets."
  value       = var.max_connections
}

output "app_secret_arn" {
  description = "ARN of the application (DML-only) credentials secret."
  value       = aws_secretsmanager_secret.db["app"].arn
}

output "migrator_secret_arn" {
  description = "ARN of the migrator (schema owner) credentials secret."
  value       = aws_secretsmanager_secret.db["migrator"].arn
}

output "master_secret_arn" {
  description = "ARN of the RDS-managed master secret, for bootstrap and break-glass only."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "instance_id" {
  description = "Identifier of the RDS instance."
  value       = aws_db_instance.this.identifier
}
