"""O1: every CDEvent type in the recorded HolmesGPT fixtures' timeline bodies is a type the
vendored CDEvents v0.5.1 schemas define (for example change.merged is 0.3.0, not 0.4.0).

The schemas live in cdevents-sim/schemas/v0.5.1 at the repo root. CDEVENTS_SCHEMA_DIR
points somewhere else (a worktree checks against the sim worktree's copy)."""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

FIXTURES = Path(__file__).parent / "fixtures" / "holmes"
REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_DIR = Path(os.environ.get("CDEVENTS_SCHEMA_DIR", REPO_ROOT / "cdevents-sim" / "schemas" / "v0.5.1"))


def _schema_types() -> set[str]:
    types: set[str] = set()
    for path in SCHEMA_DIR.glob("*.json"):
        spec = json.loads(path.read_text())["properties"]["context"]["properties"]["type"]
        types.update(spec.get("enum", []))
        if "const" in spec:
            types.add(spec["const"])
    return types


def _timeline_types(name: str) -> list[str]:
    raw = json.loads((FIXTURES / name).read_text())
    found: list[str] = []
    for call in raw["tool_calls"]:
        data = json.loads(call["result"].get("data") or "{}")
        body = data.get("body")
        if isinstance(body, list):
            found.extend(row["type"] for row in body if isinstance(row, dict) and "type" in row)
    return found


@pytest.mark.skipif(not SCHEMA_DIR.is_dir(), reason="vendored CDEvents schemas not on this branch yet (wt/sim)")
@pytest.mark.parametrize("name", ["rca_ok.json", "rca_toolcall_timeline.json"])
def test_fixture_timeline_types_are_in_the_vendored_schema(name: str) -> None:
    known = _schema_types()
    assert known, f"no schemas under {SCHEMA_DIR}"
    types = _timeline_types(name)
    assert types, f"{name} has no timeline rows"
    assert [t for t in types if t not in known] == []
