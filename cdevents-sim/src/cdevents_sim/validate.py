"""CDEvent validation against the vendored v0.5.1 schemas."""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, validators

_HERE = Path(__file__).resolve().parent
_CANDIDATES = [
    _HERE / "schemas" / "v0.5.1",  # installed wheel
    _HERE.parent.parent / "schemas" / "v0.5.1",  # source checkout
]
SCHEMA_DIR = next((p for p in _CANDIDATES if p.is_dir()), _CANDIDATES[-1])

CUSTOM_PREFIX = "dev.cdeventsx."
_TYPE_RE = re.compile(r"^dev\.cdevents\.([a-z]+)\.([a-z]+)\.\d+\.\d+\.\d+$")


class ValidationError(ValueError):
    """The event is not acceptable; str(e) is the reason returned to the sender."""


def parse_timestamp(value: Any) -> datetime:
    if not isinstance(value, str) or not value:
        raise ValidationError("context.timestamp is required")
    try:
        ts = datetime.fromisoformat(value)
    except ValueError as exc:
        raise ValidationError(f"context.timestamp is not RFC 3339: {value!r}") from exc
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts.astimezone(timezone.utc)


@lru_cache(maxsize=None)
def _validator(schema_name: str) -> Draft202012Validator:
    schema = json.loads((SCHEMA_DIR / f"{schema_name}.json").read_text())
    cls = validators.validator_for(schema, default=Draft202012Validator)
    return cls(schema)


def validate_event(event: Any) -> None:
    """Raise ValidationError with a reason, or return None when the event is fine.

    cdeventsx.* types are custom: they need a context id, type and timestamp
    but no schema. Standard types must match their v0.5.1 schema.
    """
    if not isinstance(event, dict):
        raise ValidationError("event must be a JSON object")
    ctx = event.get("context")
    if not isinstance(ctx, dict):
        raise ValidationError("context is required")
    cid = ctx.get("id")
    if not isinstance(cid, str) or not cid:
        raise ValidationError("context.id is required")
    etype = ctx.get("type")
    if not isinstance(etype, str) or not etype:
        raise ValidationError("context.type is required")
    parse_timestamp(ctx.get("timestamp"))

    if etype.startswith(CUSTOM_PREFIX):
        return
    m = _TYPE_RE.match(etype)
    if not m:
        raise ValidationError(f"unrecognised event type: {etype}")
    name = m.group(1) + m.group(2)
    if not (SCHEMA_DIR / f"{name}.json").is_file():
        raise ValidationError(f"no v0.5.1 schema for type: {etype}")
    errors = sorted(_validator(name).iter_errors(event), key=lambda e: list(e.absolute_path))
    if errors:
        e = errors[0]
        where = ".".join(str(p) for p in e.absolute_path) or "event"
        raise ValidationError(f"schema violation at {where}: {e.message}")
