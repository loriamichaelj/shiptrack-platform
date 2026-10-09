output "pod_bucket_name" {
  description = "Name of the proof-of-delivery bucket."
  value       = aws_s3_bucket.pod.id
}

output "pod_bucket_arn" {
  description = "ARN of the proof-of-delivery bucket."
  value       = aws_s3_bucket.pod.arn
}

# The ALB checks that it can write here when it is created, so the policy must exist first.
output "alb_logs_bucket_name" {
  description = "Name of the ALB access-log bucket."
  value       = aws_s3_bucket.alb_logs.id
  depends_on  = [aws_s3_bucket_policy.alb_logs]
}

output "alb_logs_bucket_arn" {
  description = "ARN of the ALB access-log bucket."
  value       = aws_s3_bucket.alb_logs.arn
}

# The trail and the Config delivery channel check that they can write here when they are created,
# so the policy must exist first.
output "cloudtrail_bucket_name" {
  description = "Name of the CloudTrail bucket."
  value       = aws_s3_bucket.cloudtrail.id
  depends_on  = [aws_s3_bucket_policy.cloudtrail]
}

output "cloudtrail_bucket_arn" {
  description = "ARN of the CloudTrail bucket."
  value       = aws_s3_bucket.cloudtrail.arn
}
