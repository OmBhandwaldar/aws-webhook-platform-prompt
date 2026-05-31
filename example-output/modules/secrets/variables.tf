variable "project_name" {
  type        = string
  description = "Short kebab-case project identifier."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-32 chars, lowercase, kebab-case."
  }
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

  validation {
    condition = length(var.providers_enabled) > 0 && alltrue([
      for p in var.providers_enabled : contains(["stripe", "github", "slack"], p)
    ])
    error_message = "providers_enabled must be a non-empty subset of [stripe, github, slack]."
  }
}
