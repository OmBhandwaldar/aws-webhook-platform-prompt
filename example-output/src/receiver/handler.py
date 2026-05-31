"""Receiver Lambda: verify signature, enforce idempotency, enqueue.

Flow:
    1. Identify provider from path parameter.
    2. Fetch signing secret from Secrets Manager (cached across warm invokes).
    3. Verify signature on the *raw* body bytes.
    4. Extract a stable event_id; conditionally PutItem to idempotency table.
    5. If new -> send to SQS with trace context; return 202.
       If duplicate -> increment metric; return 200 (so providers stop retrying).

All errors return 5xx so providers retry; signature failures return 401.
"""

from __future__ import annotations

import base64
import json
import os
import time
from typing import Any

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from botocore.config import Config

from verifiers import github as github_verifier
from verifiers import slack as slack_verifier
from verifiers import stripe as stripe_verifier

# ---------------------------------------------------------------------------
# Configuration (immutable per cold start)
# ---------------------------------------------------------------------------
PROJECT_NAME = os.environ["PROJECT_NAME"]
ENVIRONMENT = os.environ["ENVIRONMENT"]
IDEMPOTENCY_TABLE = os.environ["IDEMPOTENCY_TABLE"]
QUEUE_URL = os.environ["QUEUE_URL"]
SECRET_NAME_PATTERN = os.environ["SECRET_NAME_PATTERN"]  # e.g. "webhook-platform/dev/webhook/{provider}"
IDEMPOTENCY_TTL_SECONDS = int(os.environ.get("IDEMPOTENCY_TTL_SECONDS", "86400"))
ENABLED_PROVIDERS = set(os.environ.get("ENABLED_PROVIDERS", "stripe,github,slack").split(","))

logger = Logger(service="webhook-receiver")
tracer = Tracer(service="webhook-receiver")
metrics = Metrics(namespace=f"{PROJECT_NAME}/{ENVIRONMENT}", service="webhook-receiver")

_boto_config = Config(retries={"max_attempts": 3, "mode": "standard"}, connect_timeout=2, read_timeout=5)
_secrets = boto3.client("secretsmanager", config=_boto_config)
_ddb = boto3.client("dynamodb", config=_boto_config)
_sqs = boto3.client("sqs", config=_boto_config)

# Cache secret values in-memory for the lifetime of the container.
_secret_cache: dict[str, str] = {}

VERIFIERS = {
    "stripe": stripe_verifier.verify,
    "github": github_verifier.verify,
    "slack": slack_verifier.verify,
}

EVENT_ID_EXTRACTORS = {
    "stripe": stripe_verifier.extract_event_id,
    "github": github_verifier.extract_event_id,
    "slack": slack_verifier.extract_event_id,
}


def _response(status: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, separators=(",", ":")),
    }


def _get_secret(provider: str) -> str:
    if provider in _secret_cache:
        return _secret_cache[provider]
    name = SECRET_NAME_PATTERN.format(provider=provider)
    logger.debug("fetching secret", extra={"secret_name": name})
    resp = _secrets.get_secret_value(SecretId=name)
    raw = resp.get("SecretString") or ""
    try:
        parsed = json.loads(raw)
        value = parsed.get("signing_secret") or parsed.get("secret") or raw
    except json.JSONDecodeError:
        value = raw
    if not value:
        raise RuntimeError(f"empty signing secret for provider={provider}")
    _secret_cache[provider] = value
    return value


def _raw_body(event: dict[str, Any]) -> bytes:
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        return base64.b64decode(body)
    return body.encode("utf-8")


def _normalized_headers(event: dict[str, Any]) -> dict[str, str]:
    headers = event.get("headers") or {}
    return {k.lower(): v for k, v in headers.items() if v is not None}


def _claim_idempotency(provider: str, event_id: str) -> bool:
    """Return True if this is a new event (claim succeeded), False if duplicate."""
    now = int(time.time())
    pk = f"{provider}#{event_id}"
    try:
        _ddb.put_item(
            TableName=IDEMPOTENCY_TABLE,
            Item={
                "pk": {"S": pk},
                "provider": {"S": provider},
                "event_id": {"S": event_id},
                "received_at": {"N": str(now)},
                "status": {"S": "received"},
                "ttl": {"N": str(now + IDEMPOTENCY_TTL_SECONDS)},
            },
            ConditionExpression="attribute_not_exists(pk)",
        )
        return True
    except _ddb.exceptions.ConditionalCheckFailedException:
        return False


def _enqueue(provider: str, event_id: str, raw_body: bytes, headers: dict[str, str]) -> None:
    trace_header = os.environ.get("_X_AMZN_TRACE_ID", "")
    message = {
        "provider": provider,
        "event_id": event_id,
        "body_b64": base64.b64encode(raw_body).decode("ascii"),
        "headers": headers,
        "received_at": int(time.time()),
    }
    attrs: dict[str, Any] = {
        "provider": {"DataType": "String", "StringValue": provider},
        "event_id": {"DataType": "String", "StringValue": event_id},
    }
    kwargs: dict[str, Any] = {
        "QueueUrl": QUEUE_URL,
        "MessageBody": json.dumps(message, separators=(",", ":")),
        "MessageAttributes": attrs,
    }
    if trace_header:
        kwargs["MessageSystemAttributes"] = {
            "AWSTraceHeader": {"DataType": "String", "StringValue": trace_header}
        }
    _sqs.send_message(**kwargs)


@metrics.log_metrics(capture_cold_start_metric=True)
@tracer.capture_lambda_handler
@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    path_params = event.get("pathParameters") or {}
    provider = (path_params.get("provider") or "").lower().strip()

    if provider not in ENABLED_PROVIDERS or provider not in VERIFIERS:
        logger.warning("unknown or disabled provider", extra={"provider": provider})
        metrics.add_metric(name="UnknownProvider", unit=MetricUnit.Count, value=1)
        return _response(404, {"error": "unknown provider"})

    logger.append_keys(provider=provider)

    try:
        raw_body = _raw_body(event)
        headers = _normalized_headers(event)
    except Exception:
        logger.exception("failed to decode request body")
        return _response(400, {"error": "invalid body encoding"})

    try:
        secret = _get_secret(provider)
    except Exception:
        logger.exception("failed to load signing secret")
        metrics.add_metric(name="SecretFetchError", unit=MetricUnit.Count, value=1)
        return _response(500, {"error": "secret unavailable"})

    try:
        ok = VERIFIERS[provider](raw_body=raw_body, headers=headers, secret=secret)
    except Exception:
        logger.exception("signature verifier raised")
        metrics.add_metric(name="VerifierError", unit=MetricUnit.Count, value=1)
        return _response(401, {"error": "signature verification failed"})

    if not ok:
        logger.warning("invalid signature")
        metrics.add_metric(name="InvalidSignature", unit=MetricUnit.Count, value=1)
        return _response(401, {"error": "invalid signature"})

    try:
        event_id = EVENT_ID_EXTRACTORS[provider](raw_body=raw_body, headers=headers)
    except Exception:
        logger.exception("failed to extract event_id")
        return _response(400, {"error": "could not determine event_id"})

    logger.append_keys(event_id=event_id)

    try:
        is_new = _claim_idempotency(provider, event_id)
    except Exception:
        logger.exception("idempotency claim failed")
        metrics.add_metric(name="IdempotencyError", unit=MetricUnit.Count, value=1)
        return _response(500, {"error": "idempotency store unavailable"})

    if not is_new:
        logger.info("duplicate event, skipping enqueue")
        metrics.add_metric(name="IdempotencyHits", unit=MetricUnit.Count, value=1)
        return _response(200, {"status": "duplicate", "event_id": event_id})

    try:
        _enqueue(provider, event_id, raw_body, headers)
    except Exception:
        logger.exception("failed to enqueue")
        metrics.add_metric(name="EnqueueError", unit=MetricUnit.Count, value=1)
        return _response(500, {"error": "enqueue failed"})

    metrics.add_metric(name="Accepted", unit=MetricUnit.Count, value=1)
    logger.info("accepted")
    return _response(202, {"status": "accepted", "event_id": event_id})
