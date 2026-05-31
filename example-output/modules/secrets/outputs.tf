output "secret_arns" {
  value       = { for k, v in aws_secretsmanager_secret.provider : k => v.arn }
  description = "Map of provider name to secret ARN."
}

output "secret_arn_pattern" {
  value       = "arn:aws:secretsmanager:*:*:secret:${var.project_name}/${var.environment}/webhook/*"
  description = "ARN pattern matching all webhook secrets for this environment."
}

output "secret_name_pattern" {
  value       = "${var.project_name}/${var.environment}/webhook/{provider}"
  description = "Name pattern used by the receiver Lambda for GetSecretValue lookups."
}
