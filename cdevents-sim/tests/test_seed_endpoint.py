"""POST /seed (Task 3.14): load the fixture once, reset on request, real checkout revisions (O6)."""

from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from conftest import BRIDGE_SOURCE, ts
from cdevents_sim.app import create_app
from cdevents_sim.seed import DEFAULT_FIXTURE
from test_store import operator_change_merged

REAL_OLD = "a1" * 20
REAL_NEW = "b2" * 20
BODY = {"checkout_revisions": [REAL_OLD, REAL_NEW]}


@pytest.fixture
def client(tmp_path):
    # No SEED_FIXTURE at startup: the tests drive POST /seed themselves.
    app = create_app(store_path=tmp_path / "events.jsonl", bridge_source=BRIDGE_SOURCE, seed_fixture=None)
    with TestClient(app) as c:
        yield c


def _fixture_ids() -> set[str]:
    return {e["context"]["id"] for e in json.loads(DEFAULT_FIXTURE.read_text())}


def _ids(client) -> set[str]:
    return {r["id"] for r in client.get("/events", params={"limit": 1000}).json()}


def _live(cid: str, minutes_ago: float):
    e = operator_change_merged(sha=cid.ljust(40, "0")[:40])
    e["context"]["id"] = cid
    e["context"]["timestamp"] = ts(minutes_ago)
    return e


def test_seed_endpoint_loads_fixture_once(client):
    first = client.post("/seed", json=BODY)
    assert first.status_code == 200, first.text
    assert first.json()["added"] > 0
    ids = _ids(client)
    second = client.post("/seed", json=BODY)
    assert second.status_code == 200
    assert second.json()["added"] == 0
    assert _ids(client) == ids  # idempotent on fixture id


def test_seed_reset_drops_all_live_events_by_default(client):
    client.post("/seed", json=BODY)
    one_min = _live("live-1min", 1)
    thirty_h = _live("live-30h", 30 * 60)
    assert client.post("/events", json=one_min).status_code == 202
    assert client.post("/events", json=thirty_h).status_code == 202
    r = client.post("/seed", params={"reset": "true"}, json=BODY)
    assert r.status_code == 200, r.text
    ids = _ids(client)
    assert "live-1min" not in ids and "live-30h" not in ids
    # the fixture is back exactly once
    rows = client.get("/events", params={"limit": 1000}).json()
    assert len([x for x in rows if x["id"].startswith("seed-")]) == len(ids)
    assert len(ids) == len({x["id"] for x in rows})


def test_seed_reset_honours_keep_live_hours(client):
    client.post("/seed", json=BODY)
    client.post("/events", json=_live("live-1min", 1))
    client.post("/events", json=_live("live-30h", 30 * 60))
    client.post("/events", json=_live("live-40h", 40 * 60))
    r = client.post("/seed", params={"reset": "true", "keep_live_hours": 36}, json=BODY)
    assert r.status_code == 200
    ids = _ids(client)
    assert {"live-1min", "live-30h"} <= ids
    assert "live-40h" not in ids


def test_seed_reset_twice_is_identical(client):
    client.post("/events", json=_live("live-1min", 1))
    client.post("/seed", params={"reset": "true"}, json=BODY)
    a = client.get("/events", params={"limit": 1000}).json()
    inc_a = client.get("/incidents").json()
    client.post("/seed", params={"reset": "true"}, json=BODY)
    b = client.get("/events", params={"limit": 1000}).json()
    inc_b = client.get("/incidents").json()
    strip = lambda rows: sorted(({k: v for k, v in r.items() if k != "timestamp"} for r in rows), key=lambda r: r["id"])
    assert strip(a) == strip(b)
    assert [{k: v for k, v in i.items() if k not in ("detected_at", "resolved_at")} for i in inc_a] == [
        {k: v for k, v in i.items() if k not in ("detected_at", "resolved_at")} for i in inc_b
    ]


def test_reset_survives_a_restart(tmp_path):
    path = tmp_path / "events.jsonl"
    with TestClient(create_app(store_path=path, bridge_source=BRIDGE_SOURCE, seed_fixture=None)) as c:
        c.post("/events", json=_live("live-1min", 1))
        c.post("/seed", params={"reset": "true"}, json=BODY)
        before = _ids(c)
    with TestClient(create_app(store_path=path, bridge_source=BRIDGE_SOURCE, seed_fixture=None)) as c:
        assert _ids(c) == before
        assert "live-1min" not in _ids(c)


def test_checkout_events_in_lookback_use_real_revisions(client):
    """O6: every seeded checkout event inside 72 h carries a revision the operator supplied."""
    client.post("/seed", json=BODY)
    cutoff = datetime.now(timezone.utc) - timedelta(hours=72)
    rows = client.get("/events", params={"app": "checkout", "limit": 1000}).json()
    inside = [r for r in rows if r["id"].startswith("seed-") and r["timestamp"] >= cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")]
    assert inside, "expected seeded checkout events inside the lookback"
    assert {r["revision"] for r in inside} <= {REAL_OLD, REAL_NEW}
    for r in rows:
        if r["id"].startswith("seed-") and r not in inside:
            assert re.fullmatch(r"(\d)\1{39}", r["revision"]), "older events keep placeholder revisions"


def test_without_real_revisions_no_fake_checkout_event_is_inside_lookback(client):
    r = client.post("/seed")
    assert r.status_code == 200
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=72)).strftime("%Y-%m-%dT%H:%M:%SZ")
    for row in client.get("/events", params={"app": "checkout", "limit": 1000}).json():
        assert row["timestamp"] < cutoff, row


@pytest.mark.parametrize("body", [{"checkout_revisions": ["not-a-sha"]}, {"checkout_revisions": "abc1234"}, ["x"]])
def test_seed_rejects_bad_revisions(client, body):
    assert client.post("/seed", json=body).status_code == 400


def test_seed_without_fixture_configured_uses_default(tmp_path, monkeypatch):
    monkeypatch.delenv("SEED_FIXTURE", raising=False)
    app = create_app(store_path=tmp_path / "e.jsonl", bridge_source=BRIDGE_SOURCE)
    with TestClient(app) as c:
        assert c.post("/seed").json()["added"] > 0
