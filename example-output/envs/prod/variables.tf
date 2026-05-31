variable "project_name" {
  type        = string
  description = "Short kebab-case project identifier."
  default     = "webhook-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-32 chars, lowercase, kebab-case."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment."
  default     = "prod"

  validation {
    condition     = var.environment == "prod"
    error_message = "envs/prod hardcodes environment=prod."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region."
  default     = "us-east-1"
}

variable "owner" {
  type        = string
  description = "Owner tag value."
  default     = "platform"
}

variable "cost_center" {
  type        = string
  description = "Cost center tag value."
  default     = "engineering"
}

variable "providers_enabled" {
  type        = list(string)
  description = "Enabled webhook providers."
  default     = ["stripe", "github", "slack"]
}

variable "receiver_timeout_seconds" {
  type        = number
  description = "Receiver Lambda timeout."
  default     = 10
}

variable "processor_timeout_seconds" {
  type        = number
  description = "Processor Lambda timeout."
  default     = 30
}

variable "processor_reserved_concurrency" {
  type        = number
  description = "Processor reserved concurrency."
  default     = 50
}

variable "processor_batch_size" {
  type        = number
  description = "SQS batch size."
  default     = 10
}

variable "log_retention_days" {
  type        = number
  description = "Log retention in days."
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch-supported value."
  }
}

variable "log_level" {
  type        = string
  description = "Powertools log level."
  default     = "INFO"
}

variable "idempotency_ttl_seconds" {
  type        = number
  description = "TTL on idempotency records."
  default     = 86400
}

variable "api_throttling_burst_limit" {
  type        = number
  description = "API Gateway burst throttle."
  default     = 500
}

variable "api_throttling_rate_limit" {
  type        = number
  description = "API Gateway rate throttle."
  default     = 250
}

variable "enable_custom_domain" {
  type        = bool
  description = "Custom domain switch. Prod typically wants this true."
  default     = false
}

variable "custom_domain" {
  type        = string
  description = "Custom domain FQDN."
  default     = ""
}

variable "hosted_zone_name" {
  type        = string
  description = "Route53 hosted zone."
  default     = ""
}

variable "enable_waf" {
  type        = bool
  description = "WAFv2 enabled. Recommended ON in prod."
  default     = true
}

variable "waf_rate_limit" {
  type        = number
  description = "WAF per-IP rate limit."
  default     = 2000
}

variable "resource_policy_json" {
  type        = string
  description = "API Gateway resource policy JSON; null to skip."
  default     = null
}

variable "alert_email" {
  type        = string
  description = "Alarm SNS subscriber email."
  default     = ""
}
