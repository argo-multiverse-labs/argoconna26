"""Seed a believable delivery history from a fixture with relative timestamps."""

from __future__ import annotations

import copy
import json
import re
from collections.abc import Sequence
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


_REV = re.compile(r"^[0-9a-fA-F]{7,40}$")
_TOKEN = re.compile(r"@@[A-Z_]+@@")


def check_revisions(revisions: object) -> list[str]:
    """Validate the operator's checkout revisions (oldest first): a list of hex SHAs."""
    if not isinstance(revisions, list) or not all(isinstance(r, str) and _REV.match(r) for r in revisions):
        raise ValueError("checkout_revisions must be a list of hex commit SHAs")
    return [r.lower() for r in revisions]


def _tokens(checkout_revisions: Sequence[str]) -> dict[str, str]:
    revs = list(checkout_revisions)
    out: dict[str, str] = {}
    if revs:
        out["@@CHECKOUT_REV_LATEST@@"] = revs[-1]
    if len(revs) > 1:
        out["@@CHECKOUT_REV_PREV@@"] = revs[-2]
    return out


def fixture_ids(fixture: Path) -> set[str]:
    """Every event id the fixture can produce (substitution never changes ids)."""
    return {ev["context"]["id"] for ev in json.loads(Path(fixture).read_text())}


def seed(fixture: Path, now: datetime, store: Store, checkout_revisions: Sequence[str] = ()) -> int:
    """Add the fixture's events with timestamps rewritten against now.
    Returns how many were newly added (a second call adds 0).

    O6: the fixture's recent checkout events carry @@CHECKOUT_REV_*@@ tokens. They are
    replaced with real commits from the operator's history (`checkout_revisions`, oldest
    first). An event whose token has no commit to stand for it is skipped, so no checkout
    event inside HolmesGPT's 72 h lookback ever names a revision that doesn't exist."""
    text = Path(fixture).read_text()
    tokens = _tokens(checkout_revisions)
    for token, sha in tokens.items():
        text = text.replace(token, sha)
    events = json.loads(text)
    prepared = []
    for ev in events:
        if _TOKEN.search(json.dumps(ev)):
            continue
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
