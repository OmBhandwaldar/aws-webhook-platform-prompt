terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # Backend values are intentionally left as variables — populate via
  # `terraform init -backend-config=...` or edit backend.tf after bootstrap.
  backend "s3" {
    key     = "webhook-platform/dev/terraform.tfstate"
    encrypt = true
    # bucket, region, and dynamodb_table are supplied via -backend-config
    # (see backend.tf and the Makefile `init` target).
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "Terraform"
      CostCenter  = var.cost_center
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

###############################################################################
# Resource composition.
###############################################################################
module "idempotency" {
  source = "../../modules/idempotency"

  project_name = var.project_name
  environment  = var.environment
}

module "secrets" {
  source = "../../modules/secrets"

  project_name      = var.project_name
  environment       = var.environment
  providers_enabled = var.providers_enabled
}

module "queue" {
  source = "../../modules/queue"

  project_name              = var.project_name
  environment               = var.environment
  processor_timeout_seconds = var.processor_timeout_seconds
}

module "receiver" {
  source = "../../modules/receiver"

  project_name            = var.project_name
  environment             = var.environment
  providers_enabled       = var.providers_enabled
  idempotency_table_name  = module.idempotency.table_name
  idempotency_table_arn   = module.idempotency.table_arn
  main_queue_arn          = module.queue.main_queue_arn
  main_queue_url          = module.queue.main_queue_url
  secret_arns             = module.secrets.secret_arns
  secret_name_pattern     = module.secrets.secret_name_pattern
  lambda_timeout_seconds  = var.receiver_timeout_seconds
  log_retention_days      = var.log_retention_days
  log_level               = var.log_level
  idempotency_ttl_seconds = var.idempotency_ttl_seconds
}

module "processor" {
  source = "../../modules/processor"

  project_name           = var.project_name
  environment            = var.environment
  idempotency_table_name = module.idempotency.table_name
  idempotency_table_arn  = module.idempotency.table_arn
  main_queue_arn         = module.queue.main_queue_arn
  lambda_timeout_seconds = var.processor_timeout_seconds
  reserved_concurrency   = var.processor_reserved_concurrency
  batch_size             = var.processor_batch_size
  log_retention_days     = var.log_retention_days
  log_level              = var.log_level
  force_error            = var.force_processor_error
}

module "api" {
  source = "../../modules/api"

  project_name           = var.project_name
  environment            = var.environment
  receiver_function_name = module.receiver.function_name
  receiver_invoke_arn    = module.receiver.invoke_arn
  log_retention_days     = var.log_retention_days
  throttling_burst_limit = var.api_throttling_burst_limit
  throttling_rate_limit  = var.api_throttling_rate_limit
  enable_custom_domain   = var.enable_custom_domain
  custom_domain          = var.custom_domain
  hosted_zone_name       = var.hosted_zone_name
  enable_waf             = var.enable_waf
  waf_rate_limit         = var.waf_rate_limit
  resource_policy_json   = var.resource_policy_json
}

module "observability" {
  source = "../../modules/observability"

  project_name            = var.project_name
  environment             = var.environment
  aws_region              = var.aws_region
  alert_email             = var.alert_email
  receiver_function_name  = module.receiver.function_name
  processor_function_name = module.processor.function_name
  main_queue_name         = module.queue.main_queue_name
  dlq_name                = module.queue.dlq_name
  api_name                = "${var.project_name}-${var.environment}-webhooks"
  api_stage_name          = module.api.stage_name
}
