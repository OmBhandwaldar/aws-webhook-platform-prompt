project_name      = "webhook-platform"
environment       = "dev"
aws_region        = "us-east-1"
owner             = "platform"
cost_center       = "engineering"
providers_enabled = ["stripe", "github", "slack"]

# Cost-sensitive defaults for dev:
enable_waf           = false
enable_custom_domain = false
log_retention_days   = 30
log_level            = "INFO"

# Lambdas:
receiver_timeout_seconds       = 10
processor_timeout_seconds      = 30
processor_reserved_concurrency = -1
processor_batch_size           = 10

# Throttles:
api_throttling_burst_limit = 200
api_throttling_rate_limit  = 100

# Alerts: leave empty to skip the SNS email subscription.
alert_email = ""
