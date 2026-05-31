terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

resource "aws_dynamodb_table" "idempotency" {
  name         = "${var.project_name}-${var.environment}-idempotency"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  deletion_protection_enabled = var.environment == "prod"
}

###############################################################################
# OPTIONAL: CloudTrail data events for the idempotency table.
# Enabled = richer audit trail. Cost ≈ $0.10 per 100K data events.
# Uncomment and provide an existing CloudTrail name in `var.cloudtrail_name`.
###############################################################################
# resource "aws_cloudtrail_event_data_store" "idempotency" {
#   name                           = "${var.project_name}-${var.environment}-idempotency-events"
#   advanced_event_selector {
#     name = "log-idempotency-table-data-events"
#     field_selector {
#       field  = "eventCategory"
#       equals = ["Data"]
#     }
#     field_selector {
#       field  = "resources.type"
#       equals = ["AWS::DynamoDB::Table"]
#     }
#     field_selector {
#       field  = "resources.ARN"
#       equals = [aws_dynamodb_table.idempotency.arn]
#     }
#   }
# }
