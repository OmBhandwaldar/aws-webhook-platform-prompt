"""Slack event handler. Keep `handle()` idempotent."""

from __future__ import annotations

import json
from urllib.parse import parse_qs

from aws_lambda_powertools import Logger

logger = Logger(child=True)


def handle(*, raw_body: bytes, headers: dict[str, str], event_id: str) -> None:
    text = raw_body.decode("utf-8", errors="replace")
    payload: dict = {}
    form: dict[str, list[str]] = {}
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        form = parse_qs(text)

    event_type = (payload.get("event") or {}).get("type") if payload else None
    command = form.get("command", [None])[0] if form else None

    logger.info(
        "slack event received",
        extra={
            "event_type": event_type,
            "command": command,
            "team_id": payload.get("team_id") or (form.get("team_id", [None])[0] if form else None),
            "event_id": event_id,
        },
    )

    # --- business logic dispatch -----------------------------------------
    # if event_type == "app_mention":
    #     reply(payload)
    # if command == "/deploy":
    #     trigger_deploy(form)
    # ---------------------------------------------------------------------
