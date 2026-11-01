import json
from datetime import datetime, timezone

import httpx
import pytest
import respx
from fastapi.testclient import TestClient

from conftest import BRIDGE_SOURCE, custom_event, incident, service_deployed, ts
from cdevents_sim.app import create_app
from cdevents_sim.grafana import GrafanaAnnotator
from cdevents_sim.store import Store

BASE = "http://grafana.test"

pytestmark = pytest.mark.anyio


@pytest.fixture
def anyio_backend():
    return "asyncio"


def row(type_="dev.cdevents.service.deployed.0.3.0", app="checkout", summary="service.deployed checkout aaaaaaa"):
    return {
        "id": "e1",
        "type": type_,
        "timestamp": "2026-11-02T12:00:00Z",
        "subject_id": "demo/checkout",
        "app": app,
        "revision": "a" * 40,
        "summary": summary,
        "customData": {},
    }


async def _no_sleep(_):
    return None


def annotator(**kw):
    return GrafanaAnnotator(BASE, "tok", sleep=_no_sleep, **kw)


@respx.mock
async def test_annotation_payload_shape():
    route = respx.post(f"{BASE}/api/annotations").mock(return_value=httpx.Response(200, json={"id": 1}))
    await annotator().annotate(row())
    assert route.call_count == 1
    req = route.calls[0].request
    assert req.headers["authorization"] == "Bearer tok"
    body = json.loads(req.content)
    assert body == {
        "dashboardUID": "trust-ladder",
        "panelId": 1,
        "time": int(datetime(2026, 11, 2, 12, 0, 0, tzinfo=timezone.utc).timestamp() * 1000),
        "tags": ["service.deployed", "checkout"],
        "text": "service.deployed checkout aaaaaaa",
    }


@respx.mock
async def test_tags_short_type():
    route = respx.post(f"{BASE}/api/annotations").mock(return_value=httpx.Response(200, json={}))
    await annotator().annotate(row(type_="dev.cdevents.incident.detected.0.3.0"))
    assert json.loads(route.calls[0].request.content)["tags"] == ["incident.detected", "checkout"]


@respx.mock
async def test_tags_omit_missing_app():
    route = respx.post(f"{BASE}/api/annotations").mock(return_value=httpx.Response(200, json={}))
    await annotator().annotate(row(app=None))
    assert json.loads(route.calls[0].request.content)["tags"] == ["service.deployed"]


@respx.mock
async def test_dashboard_and_panel_are_configurable():
    route = respx.post(f"{BASE}/api/annotations").mock(return_value=httpx.Response(200, json={}))
    await annotator(dashboard_uid="other", panel_id=7).annotate(row())
    body = json.loads(route.calls[0].request.content)
    assert (body["dashboardUID"], body["panelId"]) == ("other", 7)


@respx.mock
async def test_retries_three_times_then_gives_up_quietly(caplog):
    route = respx.post(f"{BASE}/api/annotations").mock(return_value=httpx.Response(500))
    await annotator().annotate(row())  # does not raise
    assert route.call_count == 3
    assert "tok" not in caplog.text


@respx.mock
async def test_retry_stops_after_success():
    route = respx.post(f"{BASE}/api/annotations").mock(
        side_effect=[httpx.ConnectError("down"), httpx.Response(200, json={})]
    )
    await annotator().annotate(row())
    assert route.call_count == 2


@respx.mock
async def test_backoff_grows():
    delays = []

    async def rec(d):
        delays.append(d)

    respx.post(f"{BASE}/api/annotations").mock(return_value=httpx.Response(500))
    await GrafanaAnnotator(BASE, "tok", sleep=rec).annotate(row())
    assert len(delays) == 2 and delays[1] > delays[0] > 0


@respx.mock
async def test_missing_token_file_skips_without_calling_grafana(tmp_path):
    route = respx.post(f"{BASE}/api/annotations").mock(return_value=httpx.Response(200, json={}))
    a = GrafanaAnnotator(BASE, token_file=tmp_path / "absent", sleep=_no_sleep)
    await a.annotate(row())
    assert route.call_count == 0


@respx.mock
async def test_token_file_is_read_on_every_call(tmp_path):
    route = respx.post(f"{BASE}/api/annotations").mock(return_value=httpx.Response(200, json={}))
    f = tmp_path / "token"
    a = GrafanaAnnotator(BASE, token_file=f, sleep=_no_sleep)
    await a.annotate(row())  # no file yet
    f.write_text("late-token\n")
    await a.annotate(row())
    assert route.call_count == 1
    assert route.calls[0].request.headers["authorization"] == "Bearer late-token"


# ---- through the app --------------------------------------------------------

class Recorder:
    def __init__(self, fail=False):
        self.rows, self.fail = [], fail

    async def annotate(self, r):
        self.rows.append(r)
        if self.fail:
            raise RuntimeError("grafana is down")


def make_client(tmp_path, rec):
    app = create_app(store_path=tmp_path / "events.jsonl", bridge_source=BRIDGE_SOURCE, annotator=rec)
    return TestClient(app)


def test_annotation_text_never_contains_root_cause(tmp_path):
    rec = Recorder()
    with make_client(tmp_path, rec) as c:
        e = custom_event(
            "dev.cdeventsx.aiops.rca.1.0.0", "rca-1",
            custom={"level": "suggest", "cause_commit_sha": "d" * 40,
                    "root_cause": "mail ops@example.com from 10.1.2.3"},
        )
        assert c.post("/events", json=e).status_code == 202
    assert len(rec.rows) == 1
    text = rec.rows[0]["summary"]
    assert "example.com" not in text and "10.1.2.3" not in text and "root_cause" not in text
    assert text == "aiops.rca suggest ddddddd"


def test_grafana_down_does_not_fail_ingest(tmp_path):
    rec = Recorder(fail=True)
    with make_client(tmp_path, rec) as c:
        r = c.post("/events", json=service_deployed("e1"))
        assert r.status_code == 202
        assert c.get("/events").json()[0]["id"] == "e1"
    assert len(rec.rows) == 1


def test_duplicates_dropped_and_invalid_are_not_annotated(tmp_path):
    rec = Recorder()
    with make_client(tmp_path, rec) as c:
        c.post("/events", json=service_deployed("e1"))
        c.post("/events", json=service_deployed("e1"))                  # duplicate
        c.post("/events", json=incident("resolved", "r1"))              # dropped: no open incident
        bad = service_deployed("e2")
        del bad["context"]["id"]
        c.post("/events", json=bad)                                     # 400
    assert [r["id"] for r in rec.rows] == ["e1"]


def test_no_annotator_without_config(tmp_path, monkeypatch):
    monkeypatch.delenv("GRAFANA_URL", raising=False)
    app = create_app(store_path=tmp_path / "events.jsonl", bridge_source=BRIDGE_SOURCE)
    with TestClient(app) as c:
        assert c.post("/events", json=service_deployed("e1")).status_code == 202
