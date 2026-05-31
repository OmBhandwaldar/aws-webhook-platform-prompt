"""Processor Lambda: consume SQS, dispatch to per-provider handler.

Contract:
    - Triggered by SQS event source mapping (batched).
    - Uses partial batch response (`batchItemFailures`) so only failed
      records are retried; successful ones are deleted.
    - Claims the idempotency record (status: received -> processing) before
      doing work; marks status: done on success, failed on terminal failure.
    - Handlers MUST be idempotent — SQS standard delivery is at-least-once
      and Lambda may invoke duplicates even after the idempotency claim.

Set env var FORCE_ERROR=true to deliberately raise (used by the validation
checklist to exercise the DLQ path).
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

from handlers import github as github_handler
from handlers import slack as slack_handler
from handlers import stripe as stripe_handler

PROJECT_NAME = os.environ["PROJECT_NAME"]
ENVIRONMENT = os.environ["ENVIRONMENT"]
IDEMPOTENCY_TABLE = os.environ["IDEMPOTENCY_TABLE"]
FORCE_ERROR = os.environ.get("FORCE_ERROR", "").lower() == "true"

logger = Logger(service="webhook-processor")
tracer = Tracer(service="webhook-processor")
metrics = Metrics(namespace=f"{PROJECT_NAME}/{ENVIRONMENT}", service="webhook-processor")

_boto_config = Config(retries={"max_attempts": 3, "mode": "standard"}, connect_timeout=2, read_timeout=10)
_ddb = boto3.client("dynamodb", config=_boto_config)

HANDLERS = {
    "stripe": stripe_handler.handle,
    "github": github_handler.handle,
    "slack": slack_handler.handle,
}


def _claim_for_processing(provider: str, event_id: str) -> bool:
    """Move status from received -> processing. Returns False if already done."""
    pk = f"{provider}#{event_id}"
    now = int(time.time())
    try:
        _ddb.update_item(
            TableName=IDEMPOTENCY_TABLE,
            Key={"pk": {"S": pk}},
            UpdateExpression="SET #s = :processing, processing_started_at = :now",
            ConditionExpression="attribute_exists(pk) AND (#s = :received OR #s = :processing)",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":received": {"S": "received"},
                ":processing": {"S": "processing"},
                ":now": {"N": str(now)},
            },
        )
        return True
    except _ddb.exceptions.ConditionalCheckFailedException:
        return False


def _mark_done(provider: str, event_id: str) -> None:
    pk = f"{provider}#{event_id}"
    now = int(time.time())
    _ddb.update_item(
        TableName=IDEMPOTENCY_TABLE,
        Key={"pk": {"S": pk}},
        UpdateExpression="SET #s = :done, processed_at = :now",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":done": {"S": "done"},
            ":now": {"N": str(now)},
        },
    )


def _mark_failed(provider: str, event_id: str, reason: str) -> None:
    pk = f"{provider}#{event_id}"
    now = int(time.time())
    try:
        _ddb.update_item(
            TableName=IDEMPOTENCY_TABLE,
            Key={"pk": {"S": pk}},
            UpdateExpression="SET #s = :failed, failed_at = :now, failure_reason = :r",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":failed": {"S": "failed"},
                ":now": {"N": str(now)},
                ":r": {"S": reason[:500]},
            },
        )
    except Exception:
        logger.exception("failed to mark idempotency record as failed")


@tracer.capture_method
def _process_record(record: dict[str, Any]) -> None:
    body = json.loads(record["body"])
    provider = body["provider"]
    event_id = body["event_id"]
    raw_body = base64.b64decode(body["body_b64"])
    headers = body.get("headers") or {}

    logger.append_keys(provider=provider, event_id=event_id)

    if provider not in HANDLERS:
        raise RuntimeError(f"no handler registered for provider={provider}")

    if FORCE_ERROR:
        raise RuntimeError("FORCE_ERROR=true is set; deliberately failing for DLQ test")

    if not _claim_for_processing(provider, event_id):
        logger.info("event already processed; skipping")
        metrics.add_metric(name="AlreadyProcessed", unit=MetricUnit.Count, value=1)
        return

    try:
        HANDLERS[provider](raw_body=raw_body, headers=headers, event_id=event_id)
    except Exception as exc:
        _mark_failed(provider, event_id, repr(exc))
        metrics.add_metric(name="HandlerError", unit=MetricUnit.Count, value=1)
        raise

    _mark_done(provider, event_id)
    metrics.add_metric(name="Processed", unit=MetricUnit.Count, value=1)


@metrics.log_metrics(capture_cold_start_metric=True)
@tracer.capture_lambda_handler
@logger.inject_lambda_context
def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    failures: list[dict[str, str]] = []
    records = event.get("Records") or []

    for record in records:
        message_id = record.get("messageId", "unknown")
        try:
            _process_record(record)
        except Exception:
            logger.exception("record processing failed", extra={"messageId": message_id})
            failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": failures}
