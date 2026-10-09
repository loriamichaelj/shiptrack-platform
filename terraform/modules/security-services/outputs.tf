output "trail_arn" {
  description = "ARN of the CloudTrail trail."
  value       = aws_cloudtrail.this.arn
}

output "guardduty_detector_id" {
  description = "ID of the GuardDuty detector."
  value       = aws_guardduty_detector.this.id
}

output "config_recorder_name" {
  description = "Name of the AWS Config recorder."
  value       = aws_config_configuration_recorder.this.name
}

output "access_analyzer_arn" {
  description = "ARN of the account analyzer."
  value       = aws_accessanalyzer_analyzer.this.arn
}
