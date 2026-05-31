output "main_queue_arn" {
  value       = aws_sqs_queue.main.arn
  description = "Main queue ARN."
}

output "main_queue_url" {
  value       = aws_sqs_queue.main.id
  description = "Main queue URL."
}

output "main_queue_name" {
  value       = aws_sqs_queue.main.name
  description = "Main queue name."
}

output "dlq_arn" {
  value       = aws_sqs_queue.dlq.arn
  description = "DLQ ARN."
}

output "dlq_url" {
  value       = aws_sqs_queue.dlq.id
  description = "DLQ URL."
}

output "dlq_name" {
  value       = aws_sqs_queue.dlq.name
  description = "DLQ name."
}
