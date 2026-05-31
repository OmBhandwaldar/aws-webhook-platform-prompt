"""Slack request signature verification (v0 scheme).

Reference: https://api.slack.com/authentication/verifying-requests-from-slack

basestring = "v0:" + timestamp + ":" + raw_body
signature  = "v0=" + hex(HMAC-SHA256(signing_secret, basestring))

Reject timestamps older than 5 minutes (replay protection).
"""

from __future__ import annotations

import hashlib
import hmac
import json
import time
from urllib.parse import parse_qs

TOLERANCE_SECONDS = 300


def verify(raw_body: bytes, headers: dict[str, str], secret: str) -> bool:
    timestamp = headers.get("x-slack-request-timestamp")
    provided = headers.get("x-slack-signature")
    if not timestamp or not provided:
        return False
    try:
        ts_int = int(timestamp)
    except ValueError:
        return False
    if abs(int(time.time()) - ts_int) > TOLERANCE_SECONDS:
        return False

    basestring = b"v0:" + timestamp.encode("ascii") + b":" + raw_body
    expected = "v0=" + hmac.new(secret.encode("utf-8"), basestring, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, provided)


def extract_event_id(raw_body: bytes, headers: dict[str, str]) -> str:
    text = raw_body.decode("utf-8", errors="replace")

    # Slack Events API posts JSON with an "event_id" at the top level.
    try:
        payload = json.loads(text)
        if isinstance(payload, dict):
            for key in ("event_id", "trigger_id"):
                if payload.get(key):
                    return str(payload[key])
            event = payload.get("event") or {}
            if isinstance(event, dict) and event.get("client_msg_id"):
                return str(event["client_msg_id"])
    except json.JSONDecodeError:
        pass

    # Slash commands / interactivity post form-encoded bodies.
    try:
        form = parse_qs(text)
        for key in ("trigger_id", "api_app_id"):
            if form.get(key):
                return form[key][0]
    except Exception:
        pass

    # Fall back to the timestamp header + a hash of the body so we still
    # have a stable id for replays of identical payloads.
    ts = headers.get("x-slack-request-timestamp", "0")
    digest = hashlib.sha256(raw_body).hexdigest()[:16]
    return f"slack-{ts}-{digest}"
