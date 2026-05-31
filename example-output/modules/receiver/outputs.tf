output "function_name" {
  value       = aws_lambda_function.this.function_name
  description = "Receiver Lambda function name."
}

output "function_arn" {
  value       = aws_lambda_function.this.arn
  description = "Receiver Lambda function ARN."
}

output "invoke_arn" {
  value       = aws_lambda_function.this.invoke_arn
  description = "Invoke ARN used by API Gateway."
}

output "role_name" {
  value       = aws_iam_role.this.name
  description = "Lambda execution role name."
}

output "log_group_name" {
  value       = aws_cloudwatch_log_group.this.name
  description = "CloudWatch log group."
}
