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

variable "processor_timeout_seconds" {
  type        = number
  description = "Processor Lambda timeout. Used to compute SQS visibility timeout (6x)."

  validation {
    condition     = var.processor_timeout_seconds >= 5 && var.processor_timeout_seconds <= 900
    error_message = "processor_timeout_seconds must be between 5 and 900."
  }
}
