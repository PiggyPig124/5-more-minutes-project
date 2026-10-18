"""Strict explicit task instants shared by confirmation and local DEMO parsing."""
from datetime import datetime, timezone
import re

ISO_DUE_AT = (
    r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}'
    r'(?::[0-9]{2}(?:\.[0-9]{1,6})?)?(Z|[+-][0-9]{2}:[0-9]{2})'
)


def parse_due_at(value: object) -> datetime | None:
    # No date-only, zone inference, unknown -00:00 offset or parser overflow.
    if not isinstance(value, str):
        return None
    match = re.fullmatch(ISO_DUE_AT, value)
    if match is None or match[1] == '-00:00':
        return None
    offset = match[1]
    if offset != 'Z':
        hours, minutes = int(offset[1:3]), int(offset[4:6])
        if hours > 14 or minutes > 59 or (hours == 14 and minutes != 0):
            return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.astimezone(timezone.utc)
    except (TypeError, ValueError, OverflowError):
        return None


def explicit_demo_due_at(text: str) -> str | None:
    """Keep one complete future ISO instant; never infer a date or time zone."""
    dates = list(re.finditer(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', text))
    if len(dates) != 1:
        return None
    start, end = dates[0].span()
    # Keep the entire printable ASCII token, including invalid prefix/suffix
    # characters. Chinese text and whitespace bound the explicitly typed ISO.
    while start > 0 and '!' <= text[start - 1] <= '~':
        start -= 1
    while end < len(text) and '!' <= text[end] <= '~':
        end += 1
    raw = text[start:end].strip("()[]{}<>\"'.,!?;")
    parsed = parse_due_at(raw)
    return raw if parsed is not None and parsed > datetime.now(timezone.utc) else None
