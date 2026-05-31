output "webhook_base_url" {
  value       = module.api.webhook_base_url
  description = "Base URL for provider webhook configuration (append /stripe, /github, /slack)."
}

output "api_invoke_url" {
  value       = module.api.invoke_url
  description = "Raw API Gateway invoke URL."
}

output "receiver_function_name" {
  value       = module.receiver.function_name
  description = "Receiver Lambda name."
}

output "processor_function_name" {
  value       = module.processor.function_name
  description = "Processor Lambda name."
}

output "idempotency_table" {
  value       = module.idempotency.table_name
  description = "DynamoDB idempotency table name."
}

output "main_queue_url" {
  value       = module.queue.main_queue_url
  description = "Main SQS queue URL."
}

output "dlq_url" {
  value       = module.queue.dlq_url
  description = "DLQ URL."
}

output "sns_alarm_topic_arn" {
  value       = module.observability.sns_topic_arn
  description = "Subscribe humans to this for alerts."
}

output "secret_arns" {
  value       = module.secrets.secret_arns
  description = "Map of provider -> Secrets Manager ARN to populate post-deploy."
}

output "dashboard_name" {
  value       = module.observability.dashboard_name
  description = "CloudWatch dashboard."
}
