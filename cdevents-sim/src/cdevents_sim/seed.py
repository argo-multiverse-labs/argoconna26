"""Seed a believable delivery history from a fixture with relative timestamps."""

from __future__ import annotations

import copy
import json
import re
from datetime import datetime
from pathlib import Path

from .store import Store, _iso, parse_since
from .validate import ValidationError, parse_timestamp, validate_event

_HERE = Path(__file__).resolve().parent
DEFAULT_FIXTURE = next(
    (p for p in (_HERE / "fixtures" / "seed-history.json", _HERE.parent.parent / "fixtures" / "seed-history.json") if p.is_file()),
    _HERE.parent.parent / "fixtures" / "seed-history.json",
)
_REL_COMPOUND = re.compile(r"^-((?:\d+[dhms])+)$")
_PART = re.compile(r"(\d+)([dhms])")


def _resolve(value: str, now: datetime) -> str:
    """Resolve '-72h' or '-1h30m' against now; pass absolute timestamps through."""
    m = _REL_COMPOUND.match(value)
    if not m:
        return _iso(parse_timestamp(value))
    ts = now
    for n, unit in _PART.findall(m.group(1)):
        ts = parse_since(f"-{n}{unit}", ts)  # type: ignore[assignment]
    return _iso(ts)


def seed(fixture: Path, now: datetime, store: Store) -> int:
    """Add the fixture's events with timestamps rewritten against now.
    Returns how many were newly added (a second call adds 0)."""
    events = json.loads(Path(fixture).read_text())
    prepared = []
    for ev in events:
        ev = copy.deepcopy(ev)
        ev["context"]["timestamp"] = _resolve(ev["context"]["timestamp"], now)
        validate_event(ev)
        prepared.append(ev)
    prepared.sort(key=lambda e: e["context"]["timestamp"])  # oldest first, so incidents match
    added = 0
    for ev in prepared:
        if store.add(ev).status == "accepted":
            added += 1
    return added
