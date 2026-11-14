from __future__ import annotations

from datetime import datetime, timezone

def utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def ensure_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).replace(microsecond=0)


def format_iso(value: datetime) -> str:
    return ensure_utc(value).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value: str) -> datetime:
    text = value.strip()
    if not text.endswith("Z") or len(text.encode("utf-8")) > 40:
        raise ValueError("invalid iso8601")
    parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("invalid iso8601")
    return parsed.astimezone(timezone.utc)


def parse_date(value: str) -> datetime:
    text = value.strip()
    if len(text) == 10:
        return datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    return parse_iso(text)
