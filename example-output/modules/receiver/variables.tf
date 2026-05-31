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

variable "providers_enabled" {
  type        = list(string)
  description = "Enabled webhook providers."
}

variable "idempotency_table_name" {
  type        = string
  description = "DynamoDB idempotency table name."
}

variable "idempotency_table_arn" {
  type        = string
  description = "DynamoDB idempotency table ARN."
}

variable "idempotency_ttl_seconds" {
  type        = number
  description = "TTL applied to idempotency records, in seconds."
  default     = 86400

  validation {
    condition     = var.idempotency_ttl_seconds >= 3600 && var.idempotency_ttl_seconds <= 604800
    error_message = "idempotency_ttl_seconds must be between 1 hour and 7 days."
  }
}

variable "main_queue_arn" {
  type        = string
  description = "Main SQS queue ARN."
}

variable "main_queue_url" {
  type        = string
  description = "Main SQS queue URL."
}

variable "secret_arns" {
  type        = map(string)
  description = "Map of provider -> Secrets Manager secret ARN."
}

variable "secret_name_pattern" {
  type        = string
  description = "Format string used by the receiver to derive secret names, with {provider} placeholder."
}

variable "lambda_timeout_seconds" {
  type        = number
  description = "Receiver Lambda timeout."
  default     = 10

  validation {
    condition     = var.lambda_timeout_seconds >= 3 && var.lambda_timeout_seconds <= 30
    error_message = "Receiver timeout must be between 3 and 30 seconds (keep it small — receiver returns 2xx fast)."
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
