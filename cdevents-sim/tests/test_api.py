import pytest
from fastapi.testclient import TestClient

from conftest import BRIDGE_SOURCE, change_created, change_merged, custom_event, incident, service_deployed, ts
from cdevents_sim.app import create_app


@pytest.fixture
def client(tmp_path):
    app = create_app(store_path=tmp_path / "events.jsonl", bridge_source=BRIDGE_SOURCE)
    with TestClient(app) as c:
        yield c


def test_post_valid_event_202(client):
    r = client.post("/events", json=service_deployed("e1"))
    assert r.status_code == 202
    assert r.json() == {"id": "e1"}


def test_post_invalid_400_with_reason(client):
    e = service_deployed("e1")
    del e["context"]["id"]
    r = client.post("/events", json=e)
    assert r.status_code == 400
    assert "context.id" in r.json()["error"]


def test_post_not_json_400(client):
    r = client.post("/events", content=b"nope", headers={"content-type": "application/json"})
    assert r.status_code == 400


def test_post_duplicate_200(client):
    client.post("/events", json=service_deployed("e1"))
    r = client.post("/events", json=service_deployed("e1"))
    assert r.status_code == 200 and r.json() == {"duplicate": True}


def test_post_resolved_without_open_200_dropped(client):
    r = client.post("/events", json=incident("resolved", "r1"))
    assert r.status_code == 200
    assert r.json() == {"dropped": "no open incident"}


def test_get_events_filters(client):
    client.post("/events", json=service_deployed("a", app="checkout", when=ts(600)))
    client.post("/events", json=service_deployed("b", app="checkout", when=ts(5)))
    client.post("/events", json=service_deployed("c", app="pricing", when=ts(5)))
    ids = lambda r: [x["id"] for x in r.json()]
    assert ids(client.get("/events", params={"app": "checkout"})) == ["b", "a"]
    assert ids(client.get("/events", params={"app": "checkout", "since": "-1h"})) == ["b"]
    assert ids(client.get("/events", params={"type": "service.deployed", "limit": 1})) in (["b"], ["c"])
    assert client.get("/events", params={"since": "garbage"}).status_code == 400


def test_timeline_is_delivery_only(client):
    for e in [
        service_deployed("deploy"),
        change_merged("op", source="/operator/scripts"),
        change_created("br"),
        custom_event("dev.cdeventsx.agent-action.0.1.0", "act", source="/x"),
    ]:
        assert client.post("/events", json=e).status_code == 202
    assert {r["id"] for r in client.get("/events").json()} == {"deploy", "op", "br", "act"}
    assert {r["id"] for r in client.get("/timeline").json()} == {"deploy", "op"}


def test_timeline_ignores_unknown_override_params(client):
    client.post("/events", json=custom_event("dev.cdeventsx.agent-action.0.1.0", "act"))
    client.post("/events", json=change_created("br"))
    client.post("/events", json=service_deployed("deploy"))
    for params in (
        {"include_agent": "true"}, {"all": "1"}, {"delivery_only": "false"},
        {"source": BRIDGE_SOURCE}, {"include": "agent"},
    ):
        assert [r["id"] for r in client.get("/timeline", params=params).json()] == ["deploy"]


def test_incidents_endpoint(client):
    client.post("/events", json=incident("detected", "d1", app="checkout", when=ts(5)))
    client.post("/events", json=incident("detected", "d2", app="pricing", when=ts(4)))
    assert len(client.get("/incidents").json()) == 2
    [inc] = client.get("/incidents", params={"app": "checkout"}).json()
    assert inc["resolved_at"] is None


def test_annotations_use_fixed_summary(client):
    client.post("/events", json=custom_event(
        "dev.cdeventsx.holmesgpt-rca.completed.0.1.0", "rca",
        custom={"root_cause": "leak 10.9.8.7 and a@b.co", "level": "suggest"}))
    client.post("/events", json=service_deployed("d"))
    rows = client.get("/annotations").json()
    assert len(rows) == 2
    text = str(rows)
    assert "10.9.8.7" not in text and "a@b.co" not in text
    assert {"time", "text", "tags"} <= set(rows[0])


def test_healthz_and_metrics(client):
    assert client.get("/healthz").status_code == 200
    client.post("/events", json=service_deployed("e"))
    body = client.get("/metrics").text
    assert "cdevents_sim_events_total" in body
