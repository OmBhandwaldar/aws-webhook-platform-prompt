output "sns_topic_arn" {
  value       = aws_sns_topic.alarms.arn
  description = "Alarm SNS topic ARN."
}

output "dashboard_name" {
  value       = aws_cloudwatch_dashboard.this.dashboard_name
  description = "CloudWatch dashboard name."
}
