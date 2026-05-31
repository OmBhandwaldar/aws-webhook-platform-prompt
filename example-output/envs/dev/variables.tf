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
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region."
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid region id."
  }
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

  validation {
    condition = length(var.providers_enabled) > 0 && alltrue([
      for p in var.providers_enabled : contains(["stripe", "github", "slack"], p)
    ])
    error_message = "providers_enabled must be a non-empty subset of [stripe, github, slack]."
  }
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
  default     = 10
}

variable "processor_batch_size" {
  type        = number
  description = "SQS batch size for processor invocations."
  default     = 10
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention."
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

variable "idempotency_ttl_seconds" {
  type        = number
  description = "TTL on idempotency records."
  default     = 86400
}

variable "api_throttling_burst_limit" {
  type        = number
  description = "API Gateway burst throttle."
  default     = 200
}

variable "api_throttling_rate_limit" {
  type        = number
  description = "API Gateway rate throttle (RPS)."
  default     = 100
}

variable "enable_custom_domain" {
  type        = bool
  description = "Provision custom domain + ACM. Requires custom_domain and hosted_zone_name."
  default     = false
}

variable "custom_domain" {
  type        = string
  description = "Custom domain FQDN (only used when enable_custom_domain=true)."
  default     = ""
}

variable "hosted_zone_name" {
  type        = string
  description = "Route53 hosted zone name."
  default     = ""
}

variable "enable_waf" {
  type        = bool
  description = "Provision WAFv2 ACL (~$8/month). Off by default in dev."
  default     = false
}

variable "waf_rate_limit" {
  type        = number
  description = "WAF per-IP rate limit (5-minute window)."
  default     = 2000
}

variable "resource_policy_json" {
  type        = string
  description = "API Gateway resource policy JSON; null to skip."
  default     = null
}

variable "alert_email" {
  type        = string
  description = "Email subscribed to the SNS alarm topic. Empty = skip."
  default     = ""
}

variable "force_processor_error" {
  type        = bool
  description = "If true, processor Lambda always raises (for DLQ smoke test)."
  default     = false
}
