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

variable "receiver_function_name" {
  type        = string
  description = "Receiver Lambda function name (for lambda:InvokeFunction permission)."
}

variable "receiver_invoke_arn" {
  type        = string
  description = "Receiver Lambda invoke ARN (AWS_PROXY integration uri)."
}

variable "resource_policy_json" {
  type        = string
  description = "API Gateway resource policy JSON. Pass null to skip."
  default     = null
}

variable "throttling_burst_limit" {
  type        = number
  description = "Per-method burst throttle."
  default     = 200

  validation {
    condition     = var.throttling_burst_limit >= 1
    error_message = "throttling_burst_limit must be >= 1."
  }
}

variable "throttling_rate_limit" {
  type        = number
  description = "Per-method steady-state throttle (requests/second)."
  default     = 100

  validation {
    condition     = var.throttling_rate_limit >= 1
    error_message = "throttling_rate_limit must be >= 1."
  }
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention in days for access logs."
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch-supported value."
  }
}

variable "enable_custom_domain" {
  type        = bool
  description = "If true, provision ACM + Route53 + custom domain."
  default     = false
}

variable "custom_domain" {
  type        = string
  description = "Custom domain name (e.g. hooks.example.com). Required when enable_custom_domain=true."
  default     = ""
}

variable "hosted_zone_name" {
  type        = string
  description = "Route53 hosted zone name for the custom domain's parent (e.g. example.com)."
  default     = ""
}

variable "enable_waf" {
  type        = bool
  description = "If true, attach a WAFv2 web ACL. Costs ~$8/month — leave false in dev."
  default     = false
}

variable "waf_rate_limit" {
  type        = number
  description = "Per-IP rate limit (requests in any 5-minute window) for the WAF rate rule."
  default     = 2000

  validation {
    condition     = var.waf_rate_limit >= 100 && var.waf_rate_limit <= 20000000
    error_message = "waf_rate_limit must be between 100 and 20,000,000."
  }
}
