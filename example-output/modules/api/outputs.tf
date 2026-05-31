output "api_id" {
  value       = aws_api_gateway_rest_api.this.id
  description = "REST API ID."
}

output "api_arn" {
  value       = aws_api_gateway_rest_api.this.arn
  description = "REST API ARN."
}

output "stage_name" {
  value       = aws_api_gateway_stage.this.stage_name
  description = "Deployed stage name."
}

output "stage_arn" {
  value       = aws_api_gateway_stage.this.arn
  description = "Deployed stage ARN."
}

output "invoke_url" {
  value       = aws_api_gateway_stage.this.invoke_url
  description = "Stage invoke URL (use this if no custom domain)."
}

output "custom_domain_url" {
  value       = var.enable_custom_domain ? "https://${var.custom_domain}" : null
  description = "Custom domain URL when enabled."
}

output "webhook_base_url" {
  value       = var.enable_custom_domain ? "https://${var.custom_domain}/webhooks" : "${aws_api_gateway_stage.this.invoke_url}/webhooks"
  description = "Base URL providers should POST to (append /{provider})."
}

output "execution_arn" {
  value       = aws_api_gateway_rest_api.this.execution_arn
  description = "Execution ARN used for IAM source_arn scoping."
}
