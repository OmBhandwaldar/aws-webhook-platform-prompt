terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

locals {
  # In non-prod we want destroy to be immediate so test envs don't accumulate
  # scheduled deletions that block re-create.
  recovery_window_days = var.environment == "prod" ? 30 : 0
}

resource "aws_secretsmanager_secret" "provider" {
  for_each = toset(var.providers_enabled)

  name                    = "${var.project_name}/${var.environment}/webhook/${each.key}"
  description             = "Webhook signing secret for ${each.key} (${var.environment})."
  recovery_window_in_days = local.recovery_window_days
}

# Create an empty placeholder version so the receiver Lambda's GetSecretValue
# call never returns ResourceNotFoundException before the user populates the
# real value. The placeholder is overwritten by `aws secretsmanager put-secret-value`.
resource "aws_secretsmanager_secret_version" "placeholder" {
  for_each = aws_secretsmanager_secret.provider

  secret_id     = each.value.id
  secret_string = jsonencode({ signing_secret = "REPLACE_ME", created_by = "terraform" })

  lifecycle {
    # Once the user populates the real value, never overwrite from Terraform.
    ignore_changes = [secret_string, version_stages]
  }
}
