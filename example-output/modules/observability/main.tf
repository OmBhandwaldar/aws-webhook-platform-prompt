terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

locals {
  topic_name = "${var.project_name}-${var.environment}-alarms"
}

###############################################################################
# SNS topic for all alarm notifications. Subscribe an email post-deploy:
#   aws sns subscribe --topic-arn <arn> --protocol email --notification-endpoint you@example.com
###############################################################################
resource "aws_sns_topic" "alarms" {
  name              = local.topic_name
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

###############################################################################
# CloudWatch alarms.
###############################################################################
resource "aws_cloudwatch_metric_alarm" "receiver_errors" {
  alarm_name          = "${var.project_name}-${var.environment}-receiver-5xx-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 1
  alarm_description   = "Receiver Lambda error rate > 1% over 5 minutes"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  metric_query {
    id          = "error_rate"
    expression  = "100 * errors / IF(invocations > 0, invocations, 1)"
    label       = "Error %"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Errors"
      period      = 300
      stat        = "Sum"
      dimensions  = { FunctionName = var.receiver_function_name }
    }
  }

  metric_query {
    id = "invocations"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Invocations"
      period      = 300
      stat        = "Sum"
      dimensions  = { FunctionName = var.receiver_function_name }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "processor_errors" {
  alarm_name          = "${var.project_name}-${var.environment}-processor-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 300
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Any processor error in a 5-minute window"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  dimensions          = { FunctionName = var.processor_function_name }
}

resource "aws_cloudwatch_metric_alarm" "apigw_5xx" {
  alarm_name          = "${var.project_name}-${var.environment}-apigw-5xx-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 1
  alarm_description   = "API Gateway 5xx rate > 1% over 5 minutes"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  metric_query {
    id          = "rate"
    expression  = "100 * errors / IF(count > 0, count, 1)"
    label       = "5xx %"
    return_data = true
  }
  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "5XXError"
      period      = 300
      stat        = "Sum"
      dimensions  = { ApiName = var.api_name, Stage = var.api_stage_name }
    }
  }
  metric_query {
    id = "count"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "Count"
      period      = 300
      stat        = "Sum"
      dimensions  = { ApiName = var.api_name, Stage = var.api_stage_name }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "${var.project_name}-${var.environment}-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 300
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "DLQ has messages — investigate processor failures"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  dimensions          = { QueueName = var.dlq_name }
}

resource "aws_cloudwatch_metric_alarm" "main_queue_age" {
  alarm_name          = "${var.project_name}-${var.environment}-main-queue-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 300
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  statistic           = "Maximum"
  threshold           = 60
  alarm_description   = "Oldest message in main queue > 60s — processor falling behind"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  dimensions          = { QueueName = var.main_queue_name }
}

###############################################################################
# Dashboard.
###############################################################################
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.project_name}-${var.environment}-webhooks"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Receiver — Invocations / Errors"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.receiver_function_name],
            [".", "Errors", ".", "."],
            [".", "Throttles", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Receiver — Duration (p50/p99)"
          region = var.aws_region
          period = 60
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", var.receiver_function_name, { stat = "p50" }],
            ["...", { stat = "p99" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Processor — Invocations / Errors"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.processor_function_name],
            [".", "Errors", ".", "."],
            [".", "Throttles", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Processor — Duration (p50/p99)"
          region = var.aws_region
          period = 60
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", var.processor_function_name, { stat = "p50" }],
            ["...", { stat = "p99" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "SQS — Main queue depth & oldest age"
          region = var.aws_region
          period = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.main_queue_name, { stat = "Maximum" }],
            [".", "ApproximateAgeOfOldestMessage", ".", ".", { stat = "Maximum" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "SQS — DLQ depth"
          region = var.aws_region
          period = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.dlq_name, { stat = "Maximum" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "API Gateway — 4xx / 5xx"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApiGateway", "4XXError", "ApiName", var.api_name, "Stage", var.api_stage_name],
            [".", "5XXError", ".", ".", ".", "."],
            [".", "Count", ".", ".", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "Custom — IdempotencyHits / Accepted / InvalidSignature"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          metrics = [
            ["${var.project_name}/${var.environment}", "IdempotencyHits", "service", "webhook-receiver"],
            [".", "Accepted", ".", "."],
            [".", "InvalidSignature", ".", "."],
          ]
        }
      },
    ]
  })
}
