from datetime import datetime, timedelta, timezone

import pytest

from conftest import (
    BRIDGE_SOURCE, NOW, change_created, change_merged, custom_event, incident, service_deployed, ts,
)
from cdevents_sim.seed import seed
from cdevents_sim.store import Store, parse_since


def test_duplicate_context_id_is_idempotent(store):
    assert store.add(service_deployed("x")).status == "accepted"
    assert store.add(service_deployed("x")).status == "duplicate"
    assert len(store.query()) == 1


def test_resolved_without_open_detected_dropped(store):
    r = store.add(incident("resolved", "r1"))
    assert r.status == "dropped"
    assert r.reason == "no open incident"
    assert store.query() == []
    assert store.incidents() == []


def test_resolved_closes_matching_incident(store):
    store.add(incident("detected", "d1", when=ts(5)))
    assert store.add(incident("resolved", "r1", when=ts(1))).status == "accepted"
    [inc] = store.incidents("checkout")
    assert inc["resolved_at"] is not None
    assert inc["detected_at"] < inc["resolved_at"]


def test_resolved_with_different_revision_closes_latest_open_incident(store):
    store.add(incident("detected", "d1", revision="a" * 40, when=ts(5)))
    store.add(incident("resolved", "r1", revision="f" * 40, when=ts(1)))
    [inc] = store.incidents("checkout")
    assert inc["revision"] == "a" * 40
    assert inc["resolved_at"] is not None


def test_resolved_closes_most_recent_open_only(store):
    store.add(incident("detected", "d1", revision="1" * 40, when=ts(10)))
    store.add(incident("detected", "d2", revision="2" * 40, when=ts(5)))
    store.add(incident("resolved", "r1", revision="3" * 40, when=ts(1)))
    rows = {i["revision"]: i for i in store.incidents("checkout")}
    assert rows["2" * 40]["resolved_at"] is not None
    assert rows["1" * 40]["resolved_at"] is None


def test_resolved_does_not_close_other_apps_incident(store):
    store.add(incident("detected", "d1", app="pricing", when=ts(5)))
    assert store.add(incident("resolved", "r1", app="checkout", when=ts(1))).status == "dropped"
    [inc] = store.incidents()
    assert inc["app"] == "pricing" and inc["resolved_at"] is None


def test_incident_level_comes_from_bridge_event(store):
    store.add(incident("detected", "d1", when=ts(5)))
    store.add(custom_event("dev.cdeventsx.holmesgpt-rca.completed.0.1.0", "rca", custom={"level": "suggest"}, when=ts(4)))
    [inc] = store.incidents("checkout")
    assert inc["level"] == "suggest"


def test_incident_row_shape(store):
    store.add(incident("detected", "d1", revision="b" * 40))
    [inc] = store.incidents()
    assert set(inc) == {"subject_id", "app", "revision", "detected_at", "resolved_at", "level"}
    assert inc["subject_id"].startswith("demo/checkout/incident")


def test_query_filters_app_type_since(store):
    store.add(service_deployed("old", app="checkout", when=ts(600)))
    store.add(service_deployed("new", app="checkout", when=ts(5)))
    store.add(service_deployed("other", app="pricing", when=ts(5)))
    store.add(incident("detected", "inc", app="checkout", when=ts(3)))
    assert {r["id"] for r in store.query(app="checkout")} == {"old", "new", "inc"}
    assert {r["id"] for r in store.query(app="checkout", type="service.deployed")} == {"old", "new"}
    assert {r["id"] for r in store.query(type="dev.cdevents.incident.detected.0.3.0")} == {"inc"}
    since = parse_since("-1h", datetime.now(timezone.utc))
    assert {r["id"] for r in store.query(app="checkout", since=since)} == {"new", "inc"}


def test_query_newest_first_and_limit(store):
    for i, m in enumerate([30, 20, 10]):
        store.add(service_deployed(f"e{i}", when=ts(m)))
    assert [r["id"] for r in store.query()] == ["e2", "e1", "e0"]
    assert [r["id"] for r in store.query(limit=2)] == ["e2", "e1"]


def test_row_shape(store):
    store.add(service_deployed("e", revision="abcdef1" + "0" * 33))
    [row] = store.query()
    assert set(row) == {"id", "type", "timestamp", "subject_id", "app", "revision", "summary", "customData"}
    assert row["app"] == "checkout" and row["revision"].startswith("abcdef1")
    assert row["subject_id"] == "demo/checkout"


def test_timeline_query_excludes_agent_events(store):
    store.add(service_deployed("deploy"))
    store.add(change_merged("operator-merge", source="/operator/scripts"))
    store.add(change_created("bridge-created"))  # bridge source
    store.add(change_merged("bridge-merged", source=BRIDGE_SOURCE))
    store.add(custom_event("dev.cdeventsx.holmesgpt-rca.completed.0.1.0", "rca", source="/anything"))
    store.add(custom_event("dev.cdeventsx.agent-action.0.1.0", "act"))
    store.add(incident("detected", "inc"))
    everything = {r["id"] for r in store.query()}
    assert everything == {"deploy", "operator-merge", "bridge-created", "bridge-merged", "rca", "act", "inc"}
    timeline = {r["id"] for r in store.query(delivery_only=True)}
    assert timeline == {"deploy", "operator-merge", "inc"}


def test_bridge_event_summary_uses_fixed_fields(store):
    evil = "contact bob@example.com from 10.1.2.3"
    store.add(custom_event(
        "dev.cdeventsx.holmesgpt-rca.completed.0.1.0", "rca",
        custom={"root_cause": evil, "level": "suggest", "action": "commented",
                "cause_commit_sha": "0123456789abcdef0123456789abcdef01234567"},
    ))
    store.add(custom_event(
        "dev.cdeventsx.agent-action.0.1.0", "act2",
        custom={"level": evil, "action": evil, "reason": evil, "sha": evil},
    ))
    for row in store.query():
        assert "bob@example.com" not in row["summary"]
        assert "10.1.2.3" not in row["summary"]
    rca = next(r for r in store.query() if r["id"] == "rca")
    assert rca["summary"] == "holmesgpt-rca.completed suggest commented 0123456"


def test_bridge_sourced_standard_event_also_uses_fixed_summary(store):
    e = change_created("pr", source=BRIDGE_SOURCE)
    e["customData"]["description"] = "mail me at eve@example.com"
    store.add(e)
    [row] = store.query()
    assert "eve@example.com" not in row["summary"]


def test_relative_since_parses():
    now = datetime(2026, 11, 2, 12, 0, tzinfo=timezone.utc)
    assert parse_since("-72h", now) == now - timedelta(hours=72)
    assert parse_since("-30m", now) == now - timedelta(minutes=30)
    assert parse_since("-2d", now) == now - timedelta(days=2)
    assert parse_since("2026-11-01T00:00:00Z", now) == datetime(2026, 11, 1, tzinfo=timezone.utc)
    assert parse_since(None, now) is None
    with pytest.raises(ValueError):
        parse_since("yesterday", now)


def test_seed_rewrites_relative_timestamps(tmp_path):
    import json
    fixture = tmp_path / "f.json"
    ev = service_deployed("seed-1", when="-72h")
    ev2 = service_deployed("seed-2", when="-1h30m")
    fixture.write_text(json.dumps([ev, ev2]))
    s = Store(tmp_path / "s.jsonl", bridge_source=BRIDGE_SOURCE)
    assert seed(fixture, NOW, s) == 2
    rows = {r["id"]: r for r in s.query()}
    assert rows["seed-1"]["timestamp"] == "2026-10-30T12:00:00Z"
    assert rows["seed-2"]["timestamp"] == "2026-11-02T10:30:00Z"
    assert seed(fixture, NOW, s) == 0  # idempotent


def test_shipped_fixture_seeds_valid_history(tmp_path):
    from cdevents_sim.seed import DEFAULT_FIXTURE
    s = Store(tmp_path / "s.jsonl", bridge_source=BRIDGE_SOURCE)
    n = seed(DEFAULT_FIXTURE, NOW, s)
    assert n >= 6
    assert s.query(app="checkout", type="service.deployed")
    assert all(r["timestamp"] <= "2026-11-02T12:00:00Z" for r in s.query())
    assert all(i["resolved_at"] for i in s.incidents())  # history has no open incident


def test_persistence_survives_restart(tmp_path):
    path = tmp_path / "p.jsonl"
    a = Store(path, bridge_source=BRIDGE_SOURCE)
    a.add(service_deployed("e1", when=ts(10)))
    a.add(incident("detected", "d1", when=ts(5)))
    a.add(incident("resolved", "r1", when=ts(1)))
    b = Store(path, bridge_source=BRIDGE_SOURCE)
    assert b.query() == a.query()
    assert b.incidents() == a.incidents()
    assert b.add(service_deployed("e1")).status == "duplicate"


@pytest.mark.parametrize("source", [None, "", "   "])
def test_store_refuses_without_bridge_source(tmp_path, source):
    """P16 fails closed: without the bridge's source the timeline filter can't work."""
    with pytest.raises(ValueError, match="BRIDGE_EVENT_SOURCE"):
        Store(tmp_path / "s.jsonl", bridge_source=source)


def test_torn_last_line_is_skipped_and_truncated(tmp_path, caplog):
    """A pod killed mid-append leaves a partial last line; the next start recovers."""
    path = tmp_path / "p.jsonl"
    a = Store(path, bridge_source=BRIDGE_SOURCE)
    a.add(service_deployed("e1", when=ts(10)))
    with path.open("a") as f:
        f.write('{"context":{"id":"torn","ty')
    b = Store(path, bridge_source=BRIDGE_SOURCE)
    assert [r["id"] for r in b.query()] == ["e1"]
    assert "torn" in caplog.text or "partial" in caplog.text
    b.add(service_deployed("e2", when=ts(5)))
    c = Store(path, bridge_source=BRIDGE_SOURCE)
    assert [r["id"] for r in c.query()] == ["e2", "e1"]


def test_corrupt_middle_line_still_fails(tmp_path):
    """Only a torn tail is recoverable; corruption elsewhere is not silently dropped."""
    path = tmp_path / "p.jsonl"
    a = Store(path, bridge_source=BRIDGE_SOURCE)
    a.add(service_deployed("e1", when=ts(10)))
    text = path.read_text()
    path.write_text("not json\n" + text)
    with pytest.raises(ValueError):
        Store(path, bridge_source=BRIDGE_SOURCE)


def operator_change_merged(sha="d" * 40, change_ref="PR-242") -> dict:
    """Exactly the shape Task 3.14's emit_change_event sends (Δ28): no app field."""
    return {
        "context": {
            "specversion": "0.5.1",
            "id": f"chg-{sha[:7]}",
            "source": "/argoconna26/operator",
            "type": "dev.cdevents.change.merged.0.3.0",
            "timestamp": ts(1),
        },
        "subject": {"id": sha, "content": {"repository": {"id": "argo-multiverse-labs/argoconna26"}}},
        "customData": {
            "title": "checkout: tune upstream timeout",
            "author": "operator",
            "change_ref": change_ref,
            "changed_files": ["apps/checkout/config/checkout-config.yaml", "./apps/checkout/CHANGELOG.md"],
        },
    }


def test_operator_change_event_reaches_app_timeline(store):
    store.add(operator_change_merged())
    rows = store.query(app="checkout", delivery_only=True)
    assert [r["customData"]["change_ref"] for r in rows] == ["PR-242"]
    assert rows[0]["app"] == "checkout"


def test_changed_files_across_apps_gives_no_app(store):
    e = operator_change_merged()
    e["customData"]["changed_files"] = ["apps/checkout/x.yaml", "apps/pricing/y.yaml"]
    store.add(e)
    assert store.query()[0]["app"] is None


@pytest.mark.parametrize("files", [["README.md"], ["apps/"], ["apps/../etc/x"], "apps/checkout/x", []])
def test_changed_files_without_one_app_gives_no_app(store, files):
    e = operator_change_merged()
    e["customData"]["changed_files"] = files
    store.add(e)
    assert store.query()[0]["app"] is None


def test_operator_change_event_carries_its_sha_as_revision(store):
    """emit_change_event puts the SHA only in subject.id; /timeline must still show it."""
    sha = "0123456789abcdef0123456789abcdef01234567"
    store.add(operator_change_merged(sha=sha))
    [row] = store.query(delivery_only=True)
    assert row["revision"] == sha
    assert sha[:7] in row["summary"].split()


def test_change_event_subject_that_is_not_a_sha_gives_no_revision(store):
    e = operator_change_merged()
    e["subject"]["id"] = "not-a-sha"
    store.add(e)
    assert store.query()[0]["revision"] is None
