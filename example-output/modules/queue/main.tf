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
  name_prefix = "${var.project_name}-${var.environment}"
}

###############################################################################
# Dead-letter queue.
###############################################################################
resource "aws_sqs_queue" "dlq" {
  name                       = "${local.name_prefix}-webhooks-dlq"
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = var.processor_timeout_seconds * 6
  sqs_managed_sse_enabled    = true
}

###############################################################################
# Main queue. Visibility timeout MUST be >= 6 * processor lambda timeout per
# the AWS recommendation so in-flight messages aren't redelivered while the
# processor is still working.
###############################################################################
resource "aws_sqs_queue" "main" {
  name                       = "${local.name_prefix}-webhooks"
  message_retention_seconds  = 345600 # 4 days
  visibility_timeout_seconds = var.processor_timeout_seconds * 6
  receive_wait_time_seconds  = 20 # long polling
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

# Enforce TLS in transit on both queues.
data "aws_iam_policy_document" "main_policy" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["sqs:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [aws_sqs_queue.main.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "dlq_policy" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["sqs:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [aws_sqs_queue.dlq.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.id
  policy    = data.aws_iam_policy_document.main_policy.json
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy    = data.aws_iam_policy_document.dlq_policy.json
}
