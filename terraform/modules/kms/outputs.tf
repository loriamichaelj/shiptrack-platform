output "data_key_arn" {
  description = "ARN of the data key."
  value       = aws_kms_key.data.arn
}

output "secrets_key_arn" {
  description = "ARN of the secrets key."
  value       = aws_kms_key.secrets.arn
}

output "logs_key_arn" {
  description = "ARN of the logs key."
  value       = aws_kms_key.logs.arn
}
