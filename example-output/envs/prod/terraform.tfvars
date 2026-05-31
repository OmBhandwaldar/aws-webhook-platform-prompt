project_name      = "webhook-platform"
environment       = "prod"
aws_region        = "us-east-1"
owner             = "platform"
cost_center       = "engineering"
providers_enabled = ["stripe", "github", "slack"]

enable_waf           = true
enable_custom_domain = false
# custom_domain    = "hooks.example.com"
# hosted_zone_name = "example.com"

log_retention_days = 90
log_level          = "INFO"

receiver_timeout_seconds       = 10
processor_timeout_seconds      = 30
processor_reserved_concurrency = 50
processor_batch_size           = 10

api_throttling_burst_limit = 500
api_throttling_rate_limit  = 250

alert_email = ""
