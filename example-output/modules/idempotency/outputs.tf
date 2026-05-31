output "table_name" {
  value       = aws_dynamodb_table.idempotency.name
  description = "DynamoDB idempotency table name."
}

output "table_arn" {
  value       = aws_dynamodb_table.idempotency.arn
  description = "DynamoDB idempotency table ARN."
}
