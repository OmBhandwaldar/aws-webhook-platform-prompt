output "state_bucket_name" {
  value       = aws_s3_bucket.state.id
  description = "S3 bucket name to use in the Terraform backend block."
}

output "lock_table_name" {
  value       = aws_dynamodb_table.lock.name
  description = "DynamoDB table name to use in the Terraform backend block."
}

output "aws_region" {
  value       = var.aws_region
  description = "Region for the backend block."
}
