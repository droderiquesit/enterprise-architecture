"""Helpers shared by the tools packages."""

from __future__ import annotations

import datetime as dt


def utc_now() -> str:
    """UTC timestamp as written into records, reports and selection documents (second precision, `Z`)."""
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
