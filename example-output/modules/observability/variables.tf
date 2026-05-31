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

variable "aws_region" {
  type        = string
  description = "AWS region (used in dashboard metric refs)."
}

variable "alert_email" {
  type        = string
  description = "Email address to subscribe to the alarm SNS topic. Empty = skip."
  default     = ""

  validation {
    condition     = var.alert_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be empty or a valid email address."
  }
}

variable "receiver_function_name" {
  type        = string
  description = "Receiver Lambda name (for alarm dimensions)."
}

variable "processor_function_name" {
  type        = string
  description = "Processor Lambda name (for alarm dimensions)."
}

variable "main_queue_name" {
  type        = string
  description = "Main SQS queue name."
}

variable "dlq_name" {
  type        = string
  description = "DLQ name."
}

variable "api_name" {
  type        = string
  description = "API Gateway REST API name."
}

variable "api_stage_name" {
  type        = string
  description = "API Gateway stage name."
}
