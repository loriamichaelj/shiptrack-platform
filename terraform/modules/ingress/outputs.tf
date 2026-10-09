output "alb_arn" {
  description = "ARN of the ALB."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "DNS name of the ALB."
  value       = aws_lb.this.dns_name
}

output "alb_arn_suffix" {
  description = "ARN suffix of the ALB, for CloudWatch metric dimensions."
  value       = aws_lb.this.arn_suffix
}

output "listener_arn" {
  description = "ARN of the listener that serves traffic (HTTPS with a domain, otherwise HTTP)."
  value       = local.serving_listener_arn
}

output "tg_legacy_arn" {
  description = "ARN of the legacy target group."
  value       = aws_lb_target_group.legacy.arn
}

output "tg_legacy_arn_suffix" {
  description = "ARN suffix of the legacy target group, for CloudWatch metric dimensions."
  value       = aws_lb_target_group.legacy.arn_suffix
}

output "tg_modern_arn" {
  description = "ARN of the modern target group."
  value       = aws_lb_target_group.modern.arn
}

output "tg_modern_arn_suffix" {
  description = "ARN suffix of the modern target group, for CloudWatch metric dimensions."
  value       = aws_lb_target_group.modern.arn_suffix
}

output "base_url" {
  description = "https://<domain> with a custom domain, otherwise http://<alb dns name>."
  value       = local.tls ? "https://${var.domain_name}" : "http://${aws_lb.this.dns_name}"
}

output "test_token_secret_arn" {
  description = "ARN of the secret that holds the test-routing token."
  value       = aws_secretsmanager_secret.test_token.arn
}
