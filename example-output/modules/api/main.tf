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
  api_name    = "${var.project_name}-${var.environment}-webhooks"
  stage_name  = var.environment
  binary_type = "*/*"
}

###############################################################################
# Account-level: grant API Gateway permission to write to CloudWatch Logs.
# This is a one-time per-account setting; safe to apply repeatedly (idempotent).
###############################################################################
data "aws_iam_policy_document" "apigw_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_cloudwatch" {
  name               = "${var.project_name}-${var.environment}-apigw-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume.json
}

resource "aws_iam_role_policy_attachment" "apigw_cloudwatch" {
  role       = aws_iam_role.apigw_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch.arn
  depends_on          = [aws_iam_role_policy_attachment.apigw_cloudwatch]
}

###############################################################################
# REST API.
# - Binary media type "*/*" guarantees the raw body reaches the Lambda
#   unmodified so signature verifiers see the bytes the provider signed.
# - Endpoint type REGIONAL so we can front it with a custom domain + ACM
#   without using CloudFront.
###############################################################################
resource "aws_api_gateway_rest_api" "this" {
  name                         = local.api_name
  description                  = "Webhook ingress for ${var.project_name} (${var.environment})"
  binary_media_types           = [local.binary_type]
  disable_execute_api_endpoint = false

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  # Source-IP allowlist (optional). Provider IP ranges live in
  # locals.tf; Slack has no published range and is omitted.
  policy = var.resource_policy_json
}

resource "aws_api_gateway_resource" "webhooks" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "webhooks"
}

resource "aws_api_gateway_resource" "provider" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.webhooks.id
  path_part   = "{provider}"
}

resource "aws_api_gateway_method" "post" {
  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = aws_api_gateway_resource.provider.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = false

  request_parameters = {
    "method.request.path.provider" = true
  }
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.provider.id
  http_method             = aws_api_gateway_method.post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.receiver_invoke_arn
  content_handling        = "CONVERT_TO_BINARY"
  timeout_milliseconds    = 29000
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = var.receiver_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

###############################################################################
# Deployment + stage. A redeploy is triggered whenever any wired-in resource
# changes (sha1 of the JSON-serialized graph).
###############################################################################
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.webhooks.id,
      aws_api_gateway_resource.provider.id,
      aws_api_gateway_method.post.id,
      aws_api_gateway_integration.lambda.id,
      aws_api_gateway_rest_api.this.policy,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.lambda,
  ]
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigateway/${local.api_name}/${local.stage_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_api_gateway_stage" "this" {
  stage_name           = local.stage_name
  rest_api_id          = aws_api_gateway_rest_api.this.id
  deployment_id        = aws_api_gateway_deployment.this.id
  xray_tracing_enabled = true

  # The account-level CloudWatch role must exist before the stage can enable
  # access logging; otherwise UpdateStage returns 400.
  depends_on = [aws_api_gateway_account.this]

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      userAgent      = "$context.identity.userAgent"
      integration    = "$context.integrationLatency"
      latency        = "$context.responseLatency"
    })
  }
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    logging_level          = "INFO"
    data_trace_enabled     = false # NEVER true in prod (logs full request bodies)
    throttling_burst_limit = var.throttling_burst_limit
    throttling_rate_limit  = var.throttling_rate_limit
  }
}

###############################################################################
# Optional: custom domain + ACM. Gated by enable_custom_domain.
###############################################################################
resource "aws_acm_certificate" "this" {
  count             = var.enable_custom_domain ? 1 : 0
  domain_name       = var.custom_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_route53_zone" "this" {
  count        = var.enable_custom_domain ? 1 : 0
  name         = var.hosted_zone_name
  private_zone = false
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.enable_custom_domain ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "this" {
  count                   = var.enable_custom_domain ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_api_gateway_domain_name" "this" {
  count                    = var.enable_custom_domain ? 1 : 0
  domain_name              = var.custom_domain
  regional_certificate_arn = aws_acm_certificate_validation.this[0].certificate_arn
  security_policy          = "TLS_1_2"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_base_path_mapping" "this" {
  count       = var.enable_custom_domain ? 1 : 0
  api_id      = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  domain_name = aws_api_gateway_domain_name.this[0].domain_name
}

resource "aws_route53_record" "alias" {
  count   = var.enable_custom_domain ? 1 : 0
  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.custom_domain
  type    = "A"

  alias {
    name                   = aws_api_gateway_domain_name.this[0].regional_domain_name
    zone_id                = aws_api_gateway_domain_name.this[0].regional_zone_id
    evaluate_target_health = false
  }
}

###############################################################################
# Optional: WAFv2 web ACL. Disabled by default (cost ≈ $8/month).
###############################################################################
resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0
  name  = "${local.api_name}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimitPerIP"
    priority = 3
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.api_name}-waf"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "this" {
  count        = var.enable_waf ? 1 : 0
  resource_arn = aws_api_gateway_stage.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}
