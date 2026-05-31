"""Stripe signature verification.

Reference: https://stripe.com/docs/webhooks/signatures

Header format:
    Stripe-Signature: t=<timestamp>,v1=<sig>,v1=<sig>,v0=<old>
We verify v1 (HMAC-SHA256 of "<timestamp>.<payload>") and enforce a 5-minute
tolerance window on the timestamp.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import time

TOLERANCE_SECONDS = 300


def _parse_header(header: str) -> tuple[str | None, list[str]]:
    timestamp: str | None = None
    signatures: list[str] = []
    for part in header.split(","):
        if "=" not in part:
            continue
        k, _, v = part.partition("=")
        k = k.strip()
        v = v.strip()
        if k == "t":
            timestamp = v
        elif k == "v1":
            signatures.append(v)
    return timestamp, signatures


def verify(raw_body: bytes, headers: dict[str, str], secret: str) -> bool:
    header = headers.get("stripe-signature")
    if not header:
        return False
    timestamp, signatures = _parse_header(header)
    if not timestamp or not signatures:
        return False
    try:
        ts_int = int(timestamp)
    except ValueError:
        return False
    if abs(int(time.time()) - ts_int) > TOLERANCE_SECONDS:
        return False

    signed_payload = f"{timestamp}.".encode("utf-8") + raw_body
    expected = hmac.new(secret.encode("utf-8"), signed_payload, hashlib.sha256).hexdigest()
    return any(hmac.compare_digest(expected, sig) for sig in signatures)


def extract_event_id(raw_body: bytes, headers: dict[str, str]) -> str:
    payload = json.loads(raw_body.decode("utf-8"))
    event_id = payload.get("id")
    if not event_id:
        raise ValueError("stripe payload missing 'id'")
    return str(event_id)
