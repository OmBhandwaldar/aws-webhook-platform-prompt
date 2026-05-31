variable "project_name" {
  type        = string
  description = "Short kebab-case project identifier."
}

variable "environment" {
  type        = string
  description = "Deployment environment."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "idempotency_table_name" {
  type        = string
  description = "DynamoDB idempotency table name."
}

variable "idempotency_table_arn" {
  type        = string
  description = "DynamoDB idempotency table ARN."
}

variable "main_queue_arn" {
  type        = string
  description = "Main SQS queue ARN."
}

variable "lambda_timeout_seconds" {
  type        = number
  description = "Processor Lambda timeout in seconds."
  default     = 30

  validation {
    condition     = var.lambda_timeout_seconds >= 5 && var.lambda_timeout_seconds <= 900
    error_message = "Processor timeout must be between 5 and 900 seconds."
  }
}

variable "reserved_concurrency" {
  type        = number
  description = "Reserved concurrent executions for the processor (protects downstream systems)."
  default     = 10

  validation {
    condition     = var.reserved_concurrency == -1 || (var.reserved_concurrency >= 1 && var.reserved_concurrency <= 1000)
    error_message = "reserved_concurrency must be -1 (no reservation) or between 1 and 1000."
  }
}

variable "batch_size" {
  type        = number
  description = "Number of SQS messages per Lambda invocation."
  default     = 10

  validation {
    condition     = var.batch_size >= 1 && var.batch_size <= 10
    error_message = "batch_size must be between 1 and 10 (SQS event source limit without batching window > 0)."
  }
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention in days."
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch-supported value."
  }
}

variable "log_level" {
  type        = string
  description = "Powertools log level."
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be one of DEBUG, INFO, WARNING, ERROR."
  }
}

variable "force_error" {
  type        = bool
  description = "If true, processor raises on every invocation (for exercising DLQ alarms)."
  default     = false
}
