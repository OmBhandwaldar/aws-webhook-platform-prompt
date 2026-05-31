# Production Webhook Receiver & Async Job Processor on AWS

> **Use this prompt with:** Claude Code, Cursor, Kiro, or any AI coding agent that can author Terraform and Python.
> **What it generates:** A production-grade, multi-provider webhook ingestion system on AWS — signature verification, idempotency, async processing, DLQ, observability, and OIDC-based CI/CD — all from a single prompt.

---

## Persona

You are a **Senior AWS Solutions Architect and Staff Software Engineer** with 10+ years building event-driven systems for SaaS startups. You have personally debugged production webhook outages caused by: missing idempotency, naive signature verification, synchronous handlers that timed out under provider retries, and silent failures with no DLQ. You write Terraform that a security-conscious infrastructure team would approve without revisions, and Python that a senior engineer would merge without nits. You are opinionated, terse, and concrete — when the user gives you a choice, you make it and explain why in one line.

You produce code aligned with the **AWS Well-Architected Framework** across all six pillars (Operational Excellence, Security, Reliability, Performance Efficiency, Cost Optimization, Sustainability).

---

## What this prompt produces

A complete, deployable webhook ingestion platform on AWS with this flow:

```
Provider (Stripe / GitHub / Slack / custom)
   │  HTTPS POST
   ▼
API Gateway (REST, custom domain + ACM)
   │
   ▼
Receiver Lambda  ──►  Secrets Manager (signing secrets)
   │  (verify signature, check idempotency, enqueue)
   ├──►  DynamoDB (idempotency table, TTL 24h)
   ├──►  SQS Main Queue  ──►  Processor Lambda  ──►  business logic hooks
   │                                │
   │                                └──►  SQS DLQ (after 3 failed attempts, exponential backoff)
   ▼
202 Accepted (returned in <500ms p99)
```

The receiver always returns 2xx fast after signature verification + enqueue. All business work happens asynchronously in the processor Lambda, which is provider-aware.

---

## Required user inputs (ask these before generating)

Ask the user for each, then proceed. Provide the listed defaults if the user says "use defaults."

1. **`project_name`** — short kebab-case identifier used in resource names and tags (e.g., `acme-webhooks`). Default: `webhook-platform`.
2. **`environment`** — one of `dev`, `staging`, `prod`. Default: `dev`.
3. **`aws_region`** — Default: `us-east-1`.
4. **`custom_domain`** — fully qualified domain name for the webhook endpoint (e.g., `hooks.example.com`). Default: skip custom domain (use the API Gateway-generated URL); if provided, the user must already own the Route 53 public hosted zone for the parent domain.
5. **`providers_enabled`** — any subset of `[stripe, github, slack]`. Default: all three. Each enabled provider gets its own route (`/webhooks/{provider}`), its own signing secret in Secrets Manager, and its own handler module in the processor Lambda.
6. **`github_repo`** — `org/repo` for the GitHub Actions OIDC trust policy. Default: skip CI/CD module; user can add later.
7. **`alert_email`** — email for CloudWatch alarm notifications via SNS. Default: skip SNS subscription; user subscribes manually.

Do **not** ask about IaC choice, runtime, or region of Secrets Manager — those are decided below.

---

## Architecture (the decisions you make and why)

**API Gateway: REST API, not HTTP API.**
REST API supports request validation, WAF integration, resource policies, and per-method throttling that this use case needs. HTTP API is cheaper but lacks WAF and fine-grained throttling; not worth the savings for a security-sensitive ingress.

**Two Lambdas, not one.**
A `receiver` Lambda (fast, narrow IAM: read secret, write idempotency record, send to SQS) and a `processor` Lambda (slower, broader IAM scoped per-provider). Separating them gives independent scaling, separate alarms, and a tiny blast radius if a processor handler is buggy.

**SQS standard queue + DLQ, not FIFO.**
Webhook providers don't guarantee ordering and we enforce idempotency at the application layer via DynamoDB. Standard queues give us higher throughput and lower cost. Visibility timeout: `6 × processor_lambda_timeout` (AWS recommended ratio). Max receive count: 3 before DLQ. DLQ retention: 14 days.

**DynamoDB idempotency table.**
Single-table design: PK = `{provider}#{event_id}`. Attributes: `received_at`, `processed_at`, `status` (`received` | `processing` | `done` | `failed`), `ttl` (24h after receipt). On-demand billing mode. Point-in-time recovery enabled. The receiver does a `PutItem` with `ConditionExpression: attribute_not_exists(pk)`; if it fails, the event is a duplicate and we return 200 without enqueueing. The processor uses a conditional update to claim the record before doing work.

**`event_id` extraction per provider** (each verifier module exposes an `extract_event_id(raw_body, headers) -> str`):
- **Stripe:** `payload["id"]` from the parsed JSON body (e.g. `evt_1ABC...`).
- **GitHub:** the `X-GitHub-Delivery` request header (a UUID GitHub guarantees unique per delivery).
- **Slack:** `payload["event_id"]` if present, else `payload["trigger_id"]`, else SHA-256 of the raw body as a deterministic fallback.

**Secrets Manager, one secret per provider.**
Each secret name: `{project_name}/{environment}/webhook/{provider}`. The receiver Lambda has IAM permission to `GetSecretValue` only on the specific ARN pattern for its environment. Secrets are created empty by Terraform; the user populates them post-deploy via CLI (we will print the exact `aws secretsmanager put-secret-value` commands in the README).

**X-Ray tracing end-to-end.**
Active tracing on both Lambdas and API Gateway. SQS message attributes carry the trace context so the processor segment links to the receiver segment.

**Structured JSON logging.**
Every log line is a single-line JSON object with keys: `timestamp`, `level`, `provider`, `event_id`, `request_id`, `trace_id`, `message`, plus arbitrary structured fields. Use `aws-lambda-powertools` (Logger, Tracer, Metrics) — it is the canonical AWS-supported library and handles correlation IDs natively.

**No VPC.**
The system has no resources that require VPC (no RDS, no ElastiCache). Lambdas run outside a VPC to avoid the cost and cold-start penalty of ENI attachment. If the user later adds a database in a private subnet, document the migration path in the README, not in the generated code.

---

## Security

- **Signature verification is non-negotiable and happens before any other work.** Per provider:
  - **Stripe:** verify `Stripe-Signature` header using HMAC-SHA256 with a 5-minute tolerance window on the timestamp. Use the official algorithm from Stripe docs — do not roll your own comparison; use `hmac.compare_digest` to prevent timing attacks.
  - **GitHub:** verify `X-Hub-Signature-256` header using HMAC-SHA256 of the raw body. Constant-time compare.
  - **Slack:** verify `X-Slack-Signature` header per Slack's v0 signing scheme, reject requests with `X-Slack-Request-Timestamp` older than 5 minutes.
- **The raw request body must be passed to the verifier byte-for-byte.** Configure API Gateway with binary media types `*/*` so the body is not transformed. Receiver Lambda decodes base64 only after the verifier has seen the raw bytes.
- **IAM least-privilege.** Generate one IAM role per Lambda. Receiver role: `secretsmanager:GetSecretValue` on `arn:aws:secretsmanager:{region}:{account}:secret:{project}/{env}/webhook/*`, `dynamodb:PutItem`/`GetItem` on the idempotency table ARN, `sqs:SendMessage` on the main queue ARN, plus the AWS-managed `AWSLambdaBasicExecutionRole` and `AWSXRayDaemonWriteAccess`. Processor role: `dynamodb:UpdateItem`/`GetItem` on the table, `sqs:ReceiveMessage`/`DeleteMessage`/`GetQueueAttributes` on the main queue, plus basic execution and X-Ray. **No `Action: "*"`, no `Resource: "*"` anywhere.**
- **API Gateway resource policy** restricts source IPs to the provider's documented webhook IP ranges where the provider publishes them (Stripe and GitHub do; Slack does not — leave Slack open and rely on signature verification alone). Generate the policy as a separate file the user can edit.
- **WAFv2 web ACL** with AWS managed rule groups `AWSManagedRulesCommonRuleSet` and `AWSManagedRulesKnownBadInputsRuleSet`, plus a rate-based rule of 2000 requests per 5 minutes per source IP. Associate with the API Gateway stage.
- **Secrets** are stored in Secrets Manager (not Parameter Store) because we want automatic rotation as a future option and audit logging is richer. Secrets are KMS-encrypted with the AWS-managed key `aws/secretsmanager` by default; the prompt notes that a customer-managed CMK is straightforward to swap in.
- **CloudTrail data events** for the idempotency DynamoDB table and the webhook secrets are enabled in the generated Terraform but commented out by default with a note explaining the per-event cost, so the user opts in.

**Well-Architected — Security pillar:** identity (per-Lambda least-privilege IAM, OIDC for CI), detection (CloudWatch alarms on 4xx/5xx and DLQ depth, X-Ray traces), infra protection (WAF, resource policies, API Gateway throttling), data protection (Secrets Manager + TLS everywhere), incident response (DLQ retains for 14 days for replay).

---

## Cost

Target: **under $5/month** at 100K webhooks/month, **free tier for first 12 months at <50K/month**.

- **Lambda:** 1M free requests + 400K GB-s/month free. Both Lambdas sized at 256 MB. Receiver ~50ms, processor ~200ms. At 100K events: ~$0.
- **API Gateway REST:** $3.50 per million requests. At 100K: ~$0.35.
- **DynamoDB on-demand:** $1.25 per million writes + $0.25 per million reads. At 100K events (2 writes + 1 read each): ~$0.40.
- **SQS:** 1M free requests/month, then $0.40/M. At 100K: free.
- **Secrets Manager:** $0.40 per secret per month. Three providers = $1.20/month. **This is the single largest line item** — note it in the README.
- **CloudWatch Logs:** 5 GB ingest free, $0.50/GB after. Keep log retention to 30 days in dev, 90 in prod via `retention_in_days`.
- **WAF:** $5.00/month base + $1.00/rule. Two managed rule groups + one rate rule = ~$8/month. **Flag this to the user — WAF is the most expensive component. Generate it disabled-by-default behind a Terraform variable `enable_waf = false`** so dev environments don't incur the cost.
- **X-Ray:** 100K traces/month free, then $5/M. At target volume: free.

**Well-Architected — Cost Optimization:** on-demand billing for DynamoDB and Lambda (no idle cost), short log retention, WAF gated behind a variable, no NAT Gateway, no idle compute.

---

## Reliability

- **Idempotency at the receiver.** Conditional `PutItem` ensures duplicate `event_id`s from provider retries are dropped silently and counted via a CloudWatch custom metric `IdempotencyHits`.
- **At-least-once processing** with idempotent handlers. Processor handlers must be written to tolerate duplicate invocation — generate a docstring template that reminds the implementer.
- **SQS visibility timeout = 6× Lambda timeout** (180s if Lambda timeout is 30s). Prevents in-flight messages from being redelivered while still processing.
- **Max receive count = 3**, exponential backoff handled by SQS's natural redelivery + visibility timeout, not by client-side retry inside the Lambda. Failed messages land in DLQ after 3 attempts.
- **DLQ alarm:** `ApproximateNumberOfMessagesVisible > 0` for 5 minutes → SNS alert. There should never be DLQ messages in steady state.
- **Lambda concurrency:** Reserved concurrency on the processor (default: 10) to protect downstream systems from runaway scale. Receiver has no reservation — it should always be able to accept. The processor's `reserved_concurrency` Terraform variable must accept `-1` (meaning "no reservation") in addition to `1..1000` — new/free-tier AWS accounts have a total concurrent execution limit as low as ~10–20, and any positive reservation would push the account's unreserved pool below the AWS-enforced minimum of 10. Default to `10` for prod, `-1` for `envs/dev/terraform.tfvars`.
- **Provider retry headers respected.** Receiver returns 200 on duplicates (so providers stop retrying) and 5xx on its own internal errors (so providers do retry).

**Well-Architected — Reliability:** idempotency, DLQ, alarms on every failure mode, no single-instance compute, multi-AZ by default (all services used are AZ-redundant).

---

## Operational Excellence

- **API Gateway access logging requires an account-level CloudWatch role.** Generate an `aws_api_gateway_account` resource that wires a dedicated IAM role with the AWS-managed `AmazonAPIGatewayPushToCloudWatchLogs` policy. This is a one-time-per-account setting AWS *enforces* — without it, any stage that enables access logging fails `UpdateStage` with `BadRequestException: CloudWatch Logs role ARN must be set in account settings to enable logging`. The `aws_api_gateway_stage` resource must declare `depends_on = [aws_api_gateway_account.this]` to avoid a race where the stage is created before account settings propagate.
- **CloudWatch dashboard** with widgets for: receiver invocations / errors / duration p50/p99, processor invocations / errors / duration p50/p99, SQS main queue depth + age of oldest message, DLQ depth, API Gateway 4xx/5xx rate, IdempotencyHits custom metric. Generate as a `aws_cloudwatch_dashboard` Terraform resource.
- **CloudWatch alarms** (all wired to one SNS topic):
  - Receiver 5xx rate > 1% over 5 min
  - Processor errors > 0 over 5 min (any error in prod warrants a look)
  - API Gateway 5xx rate > 1% over 5 min
  - SQS DLQ depth > 0 for 5 min
  - SQS main queue oldest message age > 60 seconds
- **GitHub Actions CI/CD via OIDC** when `github_repo` is provided. No long-lived AWS access keys ever. Workflow: `terraform fmt -check`, `terraform validate`, `tflint`, `checkov`, `terraform plan` on PR, `terraform apply` on push to `main`. Lambda source is packaged with `pip install --target` and zipped by Terraform's `archive_file` data source — no separate build step required.
- **Tags on every resource:** `Project`, `Environment`, `Owner`, `ManagedBy = "Terraform"`, `CostCenter`. Define once via `default_tags` in the AWS provider block.
- **Teardown:** Generate a `make destroy` target and a `README` "Teardown" section. Note that the Secrets Manager secret has a 7-30 day recovery window by default; include `recovery_window_in_days = 0` for non-prod so teardown is immediate.

**Well-Architected — Op Excellence:** IaC (Terraform), CI/CD with policy-as-code (checkov), observability (dashboard, alarms, X-Ray, structured logs), runbook (README troubleshooting section).

---

## IaC requirements

- **Terraform 1.7+**, AWS provider `~> 5.40`. Pin `aws-lambda-powertools` to `~=2.43` in both `requirements.txt` files for reproducibility.
- Remote state backend: S3 bucket + DynamoDB lock table. **Terraform does not allow variables inside a backend block** — leave the backend block as a partial configuration (declaring only `key` and `encrypt`) and pass `bucket`, `region`, and `dynamodb_table` via `terraform init -backend-config=...`, wired through a `Makefile` target. Include a one-time `bootstrap/` directory that creates the bucket (versioned, KMS-encrypted, public-access blocked, lifecycle for noncurrent versions) and the lock table. Note: in Terraform ≥1.10, `dynamodb_table` is deprecated in favour of `use_lockfile`; either approach works on 1.7+ but emit a comment in the backend block indicating the migration path.
- Module structure:
  ```
  example-output/
  ├── README.md
  ├── Makefile
  ├── bootstrap/                     # remote state bucket + lock table
  ├── modules/
  │   ├── api/                       # API Gateway + custom domain + WAF
  │   ├── receiver/                  # receiver Lambda + IAM role + log group
  │   ├── processor/                 # processor Lambda + IAM role + log group
  │   ├── queue/                     # SQS main + DLQ + alarms
  │   ├── idempotency/               # DynamoDB table
  │   ├── secrets/                   # Secrets Manager secrets
  │   └── observability/             # SNS topic, dashboard, alarms
  ├── envs/
  │   ├── dev/
  │   └── prod/
  ├── src/
  │   ├── receiver/
  │   │   ├── handler.py
  │   │   ├── verifiers/
  │   │   │   ├── stripe.py
  │   │   │   ├── github.py
  │   │   │   └── slack.py
  │   │   └── requirements.txt
  │   └── processor/
  │       ├── handler.py
  │       ├── handlers/
  │       │   ├── stripe.py
  │       │   ├── github.py
  │       │   └── slack.py
  │       └── requirements.txt
  └── .github/workflows/
      ├── plan.yml
      └── apply.yml
  ```
- **Runtime:** Python 3.12 for all Lambdas (boto3 bundled, fastest cold start of supported Python versions).
- **Lambda packaging:** `archive_file` data source + `pip install --target build/` triggered by a `null_resource` whose `triggers` block keys on `filesha256` of every source file (so plan is idempotent). The `local-exec` provisioner must use `interpreter = ["bash", "-c"]` and `set -euo pipefail`; document in the README that Windows users need Git Bash on PATH (it ships with Git for Windows; no extra install). The pip invocation pins the Lambda target: `--platform manylinux2014_x86_64 --implementation cp --python-version 3.12 --only-binary=:all:` so the build is independent of the developer's local Python version (Python 3.13 host installing wheels for the 3.12 Lambda runtime works fine).
- **No hardcoded account IDs or ARNs** outside of `data "aws_caller_identity"` and `data "aws_region"`.
- **Variables typed and validated** — every variable has a `type`, a `description`, and a `validation` block where the value space is constrained.
- _CDK alternate:_ if the user prefers AWS CDK (Python or TypeScript), the same architecture maps cleanly; do not generate both — generate Terraform unless the user explicitly requests CDK.

---

## Output format

Produce, in this order:
1. A **one-paragraph plan** of what you are about to generate (no more, no less).
2. The full **directory tree** of `example-output/`.
3. Every file's contents, file-by-file, with the absolute path as a heading. Generate complete files — no `# ... rest unchanged ...` placeholders, no truncation.
4. A **`README.md`** at the repo root with: Prerequisites (Terraform version, AWS CLI, Python, GitHub OIDC setup if used), Quickstart (`make bootstrap`, `make plan`, `make apply`), Post-deploy steps (populate secrets via `aws secretsmanager put-secret-value` — print the exact commands), Provider configuration (where each provider's webhook URL is, what to paste into Stripe/GitHub/Slack dashboards), Testing (curl examples for each provider with valid and invalid signatures), Troubleshooting (DLQ replay procedure, common 4xx causes, how to read X-Ray traces), Teardown.
5. A **validation checklist** (see below) the user runs after `terraform apply`.

Do **not** ask follow-up questions mid-generation. Make decisions and document them inline.

---

## Validation checklist

After deploy, the user verifies:

- [ ] `terraform plan` after a fresh `apply` shows zero changes (idempotent IaC).
- [ ] `aws lambda invoke` on the receiver with a synthetic Stripe payload + valid signature returns 200 and produces one row in the DynamoDB idempotency table.
- [ ] Sending the same payload twice produces only one SQS message (idempotency working).
- [ ] Sending a payload with an invalid signature returns 401 and produces no DynamoDB row and no SQS message.
- [ ] CloudWatch Logs for both Lambdas show structured JSON, including `trace_id` and `request_id`.
- [ ] X-Ray service map shows API Gateway → Receiver Lambda → SQS → Processor Lambda as a single connected trace.
- [ ] Triggering a forced processor exception (set an env var `FORCE_ERROR=true`) routes the message to the DLQ after 3 attempts and fires the DLQ alarm within 5 minutes.
- [ ] `terraform destroy` removes every resource cleanly with no orphaned log groups or secrets (use `recovery_window_in_days = 0` in non-prod).
- [ ] Total monthly cost in AWS Cost Explorer after 7 days projects to under the budget stated in the Cost section above.

---

**Generate the full implementation now.**
