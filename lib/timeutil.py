# Copyright (c) 2026 Kent G Lau, PhD.
# No KYC. No retained PII.
"""Timestamps in Asia/Hong_Kong (UTC+8), the owner's zone."""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

ZONE = ZoneInfo("Asia/Hong_Kong")
ZONE_LABEL = "Asia/Hong_Kong"


def now_iso() -> str:
    """Return an offset-aware ISO-8601 timestamp in Asia/Hong_Kong."""
    return datetime.now(ZONE).isoformat(timespec="seconds")


def stamp_compact() -> str:
    return datetime.now(ZONE).strftime("%Y%m%dT%H%M%S")
