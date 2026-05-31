terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

locals {
  function_name = "${var.project_name}-${var.environment}-processor"
  source_dir    = abspath("${path.root}/../../src/processor")
  build_dir     = "${path.module}/.build/processor"
}

resource "null_resource" "build" {
  triggers = {
    requirements = filesha256("${local.source_dir}/requirements.txt")
    handler      = filesha256("${local.source_dir}/handler.py")
    stripe       = filesha256("${local.source_dir}/handlers/stripe.py")
    github       = filesha256("${local.source_dir}/handlers/github.py")
    slack        = filesha256("${local.source_dir}/handlers/slack.py")
    init         = filesha256("${local.source_dir}/handlers/__init__.py")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      rm -rf "${local.build_dir}"
      mkdir -p "${local.build_dir}"
      cp "${local.source_dir}/handler.py" "${local.build_dir}/"
      cp -r "${local.source_dir}/handlers" "${local.build_dir}/"
      pip install --quiet \
        --target "${local.build_dir}" \
        --platform manylinux2014_x86_64 \
        --implementation cp \
        --python-version 3.12 \
        --only-binary=:all: \
        --upgrade \
        -r "${local.source_dir}/requirements.txt"
    EOT
  }
}

data "archive_file" "processor" {
  type        = "zip"
  source_dir  = local.build_dir
  output_path = "${path.module}/.build/processor.zip"
  depends_on  = [null_resource.build]
}

###############################################################################
# IAM role — least privilege, table and queue ARNs only.
###############################################################################
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${local.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

data "aws_iam_policy_document" "inline" {
  statement {
    sid     = "ManageIdempotency"
    actions = ["dynamodb:UpdateItem", "dynamodb:GetItem"]
    resources = [
      var.idempotency_table_arn,
    ]
  }

  statement {
    sid = "ConsumeMainQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [var.main_queue_arn]
  }
}

resource "aws_iam_role_policy" "inline" {
  name   = "${local.function_name}-inline"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.inline.json
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "this" {
  function_name                  = local.function_name
  role                           = aws_iam_role.this.arn
  runtime                        = "python3.12"
  handler                        = "handler.lambda_handler"
  filename                       = data.archive_file.processor.output_path
  source_code_hash               = data.archive_file.processor.output_base64sha256
  memory_size                    = 256
  timeout                        = var.lambda_timeout_seconds
  architectures                  = ["x86_64"]
  reserved_concurrent_executions = var.reserved_concurrency

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      PROJECT_NAME            = var.project_name
      ENVIRONMENT             = var.environment
      IDEMPOTENCY_TABLE       = var.idempotency_table_name
      POWERTOOLS_SERVICE_NAME = "webhook-processor"
      POWERTOOLS_LOG_LEVEL    = var.log_level
      LOG_LEVEL               = var.log_level
      FORCE_ERROR             = var.force_error ? "true" : "false"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.this,
    aws_iam_role_policy.inline,
    aws_iam_role_policy_attachment.basic,
    aws_iam_role_policy_attachment.xray,
  ]
}

###############################################################################
# SQS -> Lambda event source mapping with partial batch responses.
###############################################################################
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn                   = var.main_queue_arn
  function_name                      = aws_lambda_function.this.arn
  batch_size                         = var.batch_size
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
  enabled                            = true
}
