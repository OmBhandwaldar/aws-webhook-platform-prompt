"""Stripe event handler.

REPLACE the body of `handle()` with real business logic. The wrapper
guarantees:
    * signature was verified by the receiver
    * this invocation has claimed the idempotency record
    * raw_body is the exact bytes Stripe sent

You MUST keep `handle()` idempotent — SQS is at-least-once and AWS may
re-invoke even after a successful run if the visibility timeout elapses.
"""

from __future__ import annotations

import json

from aws_lambda_powertools import Logger

logger = Logger(child=True)


def handle(*, raw_body: bytes, headers: dict[str, str], event_id: str) -> None:
    payload = json.loads(raw_body.decode("utf-8"))
    event_type = payload.get("type", "unknown")
    logger.info(
        "stripe event received",
        extra={"event_type": event_type, "stripe_event_id": event_id},
    )

    # --- business logic dispatch -----------------------------------------
    # Example pattern:
    # if event_type == "payment_intent.succeeded":
    #     fulfill_order(payload["data"]["object"])
    # elif event_type == "customer.subscription.deleted":
    #     cancel_subscription(payload["data"]["object"])
    # ---------------------------------------------------------------------
