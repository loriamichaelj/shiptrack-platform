output "sns_sev1_arn" {
  description = "ARN of the SEV1 alert topic."
  value       = aws_sns_topic.alerts["sev1"].arn
}

output "sns_sev2_arn" {
  description = "ARN of the SEV2 alert topic."
  value       = aws_sns_topic.alerts["sev2"].arn
}

output "dashboard_name" {
  description = "Name of the cutover dashboard."
  value       = aws_cloudwatch_dashboard.cutover.dashboard_name
}
