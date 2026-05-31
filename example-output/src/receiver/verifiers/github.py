"""GitHub webhook signature verification.

Reference: https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries

Header: X-Hub-Signature-256: sha256=<hex-hmac>
Algorithm: HMAC-SHA256 of the raw request body using the webhook secret.

Event id: prefer X-GitHub-Delivery (GUID per delivery).
"""

from __future__ import annotations

import hashlib
import hmac


def verify(raw_body: bytes, headers: dict[str, str], secret: str) -> bool:
    header = headers.get("x-hub-signature-256")
    if not header or not header.startswith("sha256="):
        return False
    provided = header.split("=", 1)[1].strip()
    expected = hmac.new(secret.encode("utf-8"), raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, provided)


def extract_event_id(raw_body: bytes, headers: dict[str, str]) -> str:
    delivery = headers.get("x-github-delivery")
    if not delivery:
        raise ValueError("missing X-GitHub-Delivery header")
    return delivery
