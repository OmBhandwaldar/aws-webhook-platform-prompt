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
  function_name = "${var.project_name}-${var.environment}-receiver"
  source_dir    = abspath("${path.root}/../../src/receiver")
  build_dir     = "${path.module}/.build/receiver"
}

###############################################################################
# Lambda packaging: pip install --target build/, then archive_file zips it.
# A null_resource keyed on source hashes triggers a rebuild only when src
# files or requirements change, keeping `terraform plan` idempotent.
###############################################################################
resource "null_resource" "build" {
  triggers = {
    requirements = filesha256("${local.source_dir}/requirements.txt")
    handler      = filesha256("${local.source_dir}/handler.py")
    stripe       = filesha256("${local.source_dir}/verifiers/stripe.py")
    github       = filesha256("${local.source_dir}/verifiers/github.py")
    slack        = filesha256("${local.source_dir}/verifiers/slack.py")
    init         = filesha256("${local.source_dir}/verifiers/__init__.py")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      rm -rf "${local.build_dir}"
      mkdir -p "${local.build_dir}"
      cp "${local.source_dir}/handler.py" "${local.build_dir}/"
      cp -r "${local.source_dir}/verifiers" "${local.build_dir}/"
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

data "archive_file" "receiver" {
  type        = "zip"
  source_dir  = local.build_dir
  output_path = "${path.module}/.build/receiver.zip"
  depends_on  = [null_resource.build]
}

###############################################################################
# IAM role — least privilege, no wildcards on Resource.
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
    sid       = "ReadWebhookSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [for arn in values(var.secret_arns) : arn]
  }

  statement {
    sid     = "WriteIdempotency"
    actions = ["dynamodb:PutItem", "dynamodb:GetItem"]
    resources = [
      var.idempotency_table_arn,
    ]
  }

  statement {
    sid       = "SendToMainQueue"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [var.main_queue_arn]
  }
}

resource "aws_iam_role_policy" "inline" {
  name   = "${local.function_name}-inline"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.inline.json
}

###############################################################################
# Log group with explicit retention (no implicit creation by Lambda).
###############################################################################
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

###############################################################################
# Lambda function.
###############################################################################
resource "aws_lambda_function" "this" {
  function_name    = local.function_name
  role             = aws_iam_role.this.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.receiver.output_path
  source_code_hash = data.archive_file.receiver.output_base64sha256
  memory_size      = 256
  timeout          = var.lambda_timeout_seconds
  architectures    = ["x86_64"]

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      PROJECT_NAME            = var.project_name
      ENVIRONMENT             = var.environment
      IDEMPOTENCY_TABLE       = var.idempotency_table_name
      QUEUE_URL               = var.main_queue_url
      SECRET_NAME_PATTERN     = var.secret_name_pattern
      ENABLED_PROVIDERS       = join(",", var.providers_enabled)
      IDEMPOTENCY_TTL_SECONDS = tostring(var.idempotency_ttl_seconds)
      POWERTOOLS_SERVICE_NAME = "webhook-receiver"
      POWERTOOLS_LOG_LEVEL    = var.log_level
      LOG_LEVEL               = var.log_level
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.this,
    aws_iam_role_policy.inline,
    aws_iam_role_policy_attachment.basic,
    aws_iam_role_policy_attachment.xray,
  ]
}
