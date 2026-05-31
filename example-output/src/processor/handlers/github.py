"""GitHub webhook handler.

The receiver passes the X-GitHub-Event header through in `headers`; use it
to route. Keep the body of `handle()` idempotent.
"""

from __future__ import annotations

import json

from aws_lambda_powertools import Logger

logger = Logger(child=True)


def handle(*, raw_body: bytes, headers: dict[str, str], event_id: str) -> None:
    event_type = headers.get("x-github-event", "unknown")
    try:
        payload = json.loads(raw_body.decode("utf-8"))
    except json.JSONDecodeError:
        payload = {}

    logger.info(
        "github event received",
        extra={
            "event_type": event_type,
            "delivery_id": event_id,
            "repository": (payload.get("repository") or {}).get("full_name"),
            "action": payload.get("action"),
        },
    )

    # --- business logic dispatch -----------------------------------------
    # if event_type == "push":
    #     index_commits(payload)
    # elif event_type == "pull_request" and payload.get("action") == "opened":
    #     run_pr_automation(payload)
    # ---------------------------------------------------------------------
