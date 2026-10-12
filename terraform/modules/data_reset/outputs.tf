output "document_name" {
  description = "Name of the SSM document that resets the data."
  value       = aws_ssm_document.reset_data.name
}
