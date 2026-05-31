# Webhook Platform

Production-grade multi-provider webhook ingestion on AWS — signature verification, idempotency, async processing, DLQ, observability. Deploys with Terraform + Python 3.12 Lambdas. No VPC, no Docker, no long-lived AWS keys required.

```
Provider (Stripe / GitHub / Slack)
   │  HTTPS POST
   ▼
API Gateway REST (regional, binary "*/*")
   │
   ▼
Receiver Lambda  ──►  Secrets Manager (per-provider signing secret)
   │  verify signature -> claim idempotency -> enqueue
   ├──►  DynamoDB (pk = "{provider}#{event_id}", TTL 24h)
   ├──►  SQS Main Queue  ──►  Processor Lambda  ──►  business handlers
   │                                │  ↳ 3 retries
   │                                └──►  SQS DLQ (14d retention)
   ▼
202 Accepted
```

---

## Prerequisites

| Tool       | Version |
|------------|---------|
| Terraform  | >= 1.7.0 |
| AWS CLI v2 | latest  |
| Python     | 3.12    |
| pip        | bundled |
| make       | any GNU make |
| bash       | required by the Lambda packaging step (Git Bash works on Windows) |

Configure AWS credentials (`aws configure` or a profile). The credentials need permission to manage Lambda, API Gateway, IAM, SQS, DynamoDB, Secrets Manager, CloudWatch, SNS, and (optionally) ACM / Route53 / WAFv2.

> GitHub OIDC for the workflows was skipped during generation. See `.github/workflows/plan.yml` header for what to set when you enable CI/CD.

---

## Quickstart (dev)

```bash
# 0. One-time: create the remote state bucket + lock table.
make bootstrap

# Copy the two outputs:
#   state_bucket_name = "webhook-platform-tfstate-<acct>-us-east-1"
#   lock_table_name   = "webhook-platform-tfstate-lock"

# 1. Initialize the dev env against that backend.
make init ENV=dev \
  BUCKET=webhook-platform-tfstate-<acct>-us-east-1 \
  TABLE=webhook-platform-tfstate-lock

# 2. Plan + apply.
make plan  ENV=dev
make apply ENV=dev

# 3. Print outputs (webhook URL, secret ARNs, dashboard, etc.)
make outputs ENV=dev
```

---

## Post-deploy: populate signing secrets

Terraform creates each Secrets Manager secret with a `REPLACE_ME` placeholder. The receiver Lambda will return 5xx until you put the real signing secret. Use one command per enabled provider:

```bash
PROJECT=webhook-platform
ENV=dev
REGION=us-east-1

# Stripe — copy from Dashboard > Developers > Webhooks > Signing secret
aws secretsmanager put-secret-value \
  --region $REGION \
  --secret-id "$PROJECT/$ENV/webhook/stripe" \
  --secret-string '{"signing_secret":"whsec_xxxxxxxxxxxxxxxxxxxxxxxxxxxx"}'

# GitHub — the secret you set when creating the repo/org webhook
aws secretsmanager put-secret-value \
  --region $REGION \
  --secret-id "$PROJECT/$ENV/webhook/github" \
  --secret-string '{"signing_secret":"your-github-webhook-secret"}'

# Slack — App config > Basic Information > Signing Secret
aws secretsmanager put-secret-value \
  --region $REGION \
  --secret-id "$PROJECT/$ENV/webhook/slack" \
  --secret-string '{"signing_secret":"your-slack-signing-secret"}'
```

Verify:

```bash
aws secretsmanager get-secret-value --secret-id "$PROJECT/$ENV/webhook/stripe" --query SecretString --output text
```

If you want to subscribe an email to the alarm topic post-deploy:

```bash
aws sns subscribe \
  --topic-arn $(cd envs/dev && terraform output -raw sns_alarm_topic_arn) \
  --protocol email --notification-endpoint you@example.com
```

---

## Provider configuration

Get the base URL:

```bash
cd envs/dev && terraform output -raw webhook_base_url
# e.g. https://abc123xyz.execute-api.us-east-1.amazonaws.com/dev/webhooks
```

Paste these endpoints into each provider's dashboard:

| Provider | URL                                       | Header used |
|----------|-------------------------------------------|-------------|
| Stripe   | `<base>/stripe`                           | `Stripe-Signature` |
| GitHub   | `<base>/github` (content type `application/json`) | `X-Hub-Signature-256` |
| Slack    | `<base>/slack`                            | `X-Slack-Signature` + `X-Slack-Request-Timestamp` |

For Stripe, after creating the endpoint in Dashboard > Developers > Webhooks, copy the Signing secret back into Secrets Manager.

---

## Testing

### Stripe — valid signature

```bash
SECRET='whsec_test_dummy_value_for_local_signing'
PAYLOAD='{"id":"evt_test_123","type":"payment_intent.succeeded","data":{"object":{}}}'
TS=$(date +%s)
SIG=$(printf "%s.%s" "$TS" "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')

curl -sS -X POST "$(cd envs/dev && terraform output -raw webhook_base_url)/stripe" \
  -H "Content-Type: application/json" \
  -H "Stripe-Signature: t=${TS},v1=${SIG}" \
  --data-raw "$PAYLOAD"
# expect 202 {"status":"accepted","event_id":"evt_test_123"}
```

Send it again — the second response should be `200 {"status":"duplicate",...}` and no second SQS message.

### Stripe — invalid signature (should 401)

```bash
curl -sS -o /dev/stdout -w "\nHTTP %{http_code}\n" -X POST "$(cd envs/dev && terraform output -raw webhook_base_url)/stripe" \
  -H "Content-Type: application/json" \
  -H "Stripe-Signature: t=$(date +%s),v1=deadbeef" \
  --data-raw '{"id":"evt_bad","type":"x"}'
```

### GitHub

```bash
SECRET='your-github-webhook-secret'
PAYLOAD='{"action":"opened","repository":{"full_name":"acme/web"}}'
SIG="sha256=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"

curl -sS -X POST "$(cd envs/dev && terraform output -raw webhook_base_url)/github" \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: pull_request" \
  -H "X-GitHub-Delivery: 11111111-2222-3333-4444-555555555555" \
  -H "X-Hub-Signature-256: $SIG" \
  --data-raw "$PAYLOAD"
```

### Slack

```bash
SECRET='your-slack-signing-secret'
PAYLOAD='{"event_id":"Ev123ABC","event":{"type":"app_mention"}}'
TS=$(date +%s)
BASESTRING="v0:${TS}:${PAYLOAD}"
SIG="v0=$(printf '%s' "$BASESTRING" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"

curl -sS -X POST "$(cd envs/dev && terraform output -raw webhook_base_url)/slack" \
  -H "Content-Type: application/json" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -H "X-Slack-Signature: $SIG" \
  --data-raw "$PAYLOAD"
```

### Direct Lambda invoke (no API Gateway)

```bash
aws lambda invoke \
  --function-name $(cd envs/dev && terraform output -raw receiver_function_name) \
  --payload "$(cat tests/sample-stripe-event.json | base64)" \
  /tmp/out.json && cat /tmp/out.json
```

---

## Troubleshooting

### `401 invalid signature`
- Verify the secret in Secrets Manager matches the provider dashboard.
- Confirm the request body is JSON (Content-Type matters for GitHub).
- Stripe / Slack: confirm `date` on your client is in sync — the 5-minute tolerance window will reject stale timestamps.
- API Gateway binary media types include `*/*`; if you've edited the module, ensure raw bytes still reach the Lambda.

### `404 unknown provider`
- Path must be `/webhooks/{stripe|github|slack}`. The `providers_enabled` variable controls which are accepted.

### Messages stuck in main queue
- Check the processor Lambda's CloudWatch logs for exceptions.
- Inspect the DynamoDB idempotency table — records with `status=processing` and an old `processing_started_at` indicate a stuck handler; the visibility timeout (`6x` Lambda timeout) will eventually expire and SQS will retry.
- If `ApproximateAgeOfOldestMessage > 60s`, the **main-queue-age** alarm fires.

### DLQ has messages — replay procedure
```bash
DLQ_URL=$(cd envs/dev && terraform output -raw dlq_url)
MAIN_URL=$(cd envs/dev && terraform output -raw main_queue_url)

# Inspect one message:
aws sqs receive-message --queue-url "$DLQ_URL" --max-number-of-messages 1

# Replay: pull from DLQ, push to main, delete from DLQ (loop until empty).
# AWS now offers `start-message-move-task` which is the official redrive path:
aws sqs start-message-move-task \
  --source-arn $(aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text) \
  --destination-arn $(aws sqs get-queue-attributes --queue-url "$MAIN_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
```

### Reading X-Ray traces
1. Console > X-Ray > Service map.
2. Pick a recent trace: API Gateway → Receiver Lambda → SQS → Processor Lambda should appear as one connected path because trace context is carried via SQS `AWSTraceHeader`.
3. The `event_id` and `provider` keys are also injected into structured logs — CloudWatch Logs Insights query:

```
fields @timestamp, level, provider, event_id, message
| filter event_id = "evt_test_123"
| sort @timestamp desc
```

### Forced DLQ drill (validation checklist)
```bash
# Flip force_processor_error=true, apply, send one event, watch the DLQ alarm fire.
cd envs/dev
terraform apply -auto-approve -var force_processor_error=true
# ...send a webhook, wait ~5 minutes, observe alarm in CloudWatch...
terraform apply -auto-approve -var force_processor_error=false
```

---

## Costs

At ~100K webhooks/month with `enable_waf=false`:

| Service              | Monthly                       |
|----------------------|-------------------------------|
| Lambda (both)        | free tier                     |
| API Gateway REST     | ~$0.35                        |
| DynamoDB on-demand   | ~$0.40                        |
| SQS                  | free                          |
| Secrets Manager      | **$0.40 / secret** (= $1.20)  |
| CloudWatch Logs      | $0–$1 depending on volume     |
| X-Ray                | free                          |
| **Total (no WAF)**   | **~$2 / month**               |
| WAFv2 (if enabled)   | + ~$8 / month                 |

Secrets Manager is the single largest line item at this volume — there is no free tier. If you only need one of the three providers, set `providers_enabled = ["stripe"]` and save $0.80/month.

---

## Teardown

```bash
# Empties + destroys everything in the env, including the secrets (non-prod
# uses recovery_window_in_days = 0 so it's immediate).
make destroy ENV=dev

# Optionally remove the remote state bucket + lock table. CAUTION: this
# deletes all Terraform state for every env in this account.
cd bootstrap && terraform destroy
```

The DynamoDB idempotency table has `deletion_protection_enabled = true` in prod — disable it before `make destroy ENV=prod`.

---

## Repo layout

```
example-output/
├── README.md                       # this file
├── Makefile
├── bootstrap/                      # one-time S3 state + DDB lock
├── modules/
│   ├── api/                        # API Gateway REST + optional custom domain + optional WAF
│   ├── receiver/                   # receiver Lambda + IAM + log group
│   ├── processor/                  # processor Lambda + event source mapping + IAM
│   ├── queue/                      # SQS main + DLQ + TLS-in-transit policy
│   ├── idempotency/                # DynamoDB single-table
│   ├── secrets/                    # Secrets Manager (one per provider)
│   └── observability/              # SNS topic + alarms + dashboard
├── envs/
│   ├── dev/                        # dev defaults (WAF off, retention 30d)
│   └── prod/                       # prod defaults (WAF on, retention 90d)
├── src/
│   ├── receiver/                   # Python 3.12 receiver
│   └── processor/                  # Python 3.12 processor
└── .github/workflows/
    ├── plan.yml                    # PR plan (needs OIDC role — see header)
    └── apply.yml                   # main push apply (needs OIDC role)
```

---

## Validation checklist

After `make apply ENV=dev`:

- [ ] `make plan ENV=dev` shows **No changes** (IaC is idempotent).
- [ ] `aws lambda invoke` on the receiver with a valid Stripe payload returns 202 and creates one DynamoDB row.
- [ ] Sending the same payload twice produces only one SQS message.
- [ ] Invalid signature returns 401, no DDB row, no SQS message.
- [ ] Both Lambda log groups contain structured JSON lines with `trace_id`, `request_id`, `provider`, `event_id`.
- [ ] X-Ray service map shows API Gateway → Receiver → SQS → Processor as one trace.
- [ ] Setting `force_processor_error=true`, re-applying, and sending a webhook lands the message in DLQ after 3 attempts and fires the DLQ alarm within 5 minutes.
- [ ] `make destroy ENV=dev` completes with no orphaned log groups or secrets (dev uses `recovery_window_in_days=0`).
- [ ] Cost Explorer projects under the budget in the Costs section after 7 days.
