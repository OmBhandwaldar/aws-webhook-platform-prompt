output "function_name" {
  value       = aws_lambda_function.this.function_name
  description = "Processor Lambda function name."
}

output "function_arn" {
  value       = aws_lambda_function.this.arn
  description = "Processor Lambda function ARN."
}

output "role_name" {
  value       = aws_iam_role.this.name
  description = "Processor execution role name."
}

output "log_group_name" {
  value       = aws_cloudwatch_log_group.this.name
  description = "CloudWatch log group."
}
