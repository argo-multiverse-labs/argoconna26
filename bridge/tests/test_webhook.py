"""Task 3.4: authenticated webhook, idempotent single-worker queue."""

from __future__ import annotations

import threading
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr

from bridge.app import create_app
from bridge.config import Settings
from bridge.models import ArgoDegradedHook

from .conftest import WEBHOOK_TOKEN, hook_body

AUTH = {"Authorization": f"Bearer {WEBHOOK_TOKEN}"}


class RecordingHandler:
    def __init__(self) -> None:
        self.calls: list[ArgoDegradedHook] = []
        self.called = threading.Event()

    async def __call__(self, hook: ArgoDegradedHook) -> None:
        self.calls.append(hook)
        self.called.set()


@pytest.fixture
def handler() -> RecordingHandler:
    return RecordingHandler()


@pytest.fixture
def client(settings: Settings, handler: RecordingHandler):
    app = create_app(settings, handler=handler)
    with TestClient(app) as c:
        yield c


def drain(client: TestClient) -> None:
    """Wait until the worker has processed everything queued (a real condition)."""
    client.portal.call(client.app.state.bridge.queue.join)


def test_missing_token_401(client: TestClient, handler: RecordingHandler) -> None:
    r = client.post("/hooks/argocd", json=hook_body())
    assert r.status_code == 401
    drain(client)
    assert handler.calls == []


def test_wrong_token_401(client: TestClient, handler: RecordingHandler) -> None:
    r = client.post("/hooks/argocd", json=hook_body(), headers={"Authorization": "Bearer nope"})
    assert r.status_code == 401
    r = client.post("/hooks/argocd", json=hook_body(), headers={"Authorization": WEBHOOK_TOKEN})
    assert r.status_code == 401
    drain(client)
    assert handler.calls == []


def test_empty_configured_token_rejects_everything(handler: RecordingHandler, settings: Settings) -> None:
    app = create_app(settings.model_copy(update={"webhook_token": SecretStr("")}), handler=handler)
    with TestClient(app) as c:
        assert c.post("/hooks/argocd", json=hook_body(), headers={"Authorization": "Bearer "}).status_code == 401
        assert c.post("/hooks/argocd", json=hook_body(), headers={"Authorization": "Bearer"}).status_code == 401
        assert c.post("/hooks/argocd", json=hook_body()).status_code == 401


def test_valid_hook_202_queued(client: TestClient, handler: RecordingHandler) -> None:
    r = client.post("/hooks/argocd", json=hook_body(), headers=AUTH)
    assert r.status_code == 202
    assert r.json() == {"incident": f"checkout@{'a' * 40}", "status": "queued"}
    assert handler.called.wait(timeout=5), "handler was never called"
    drain(client)
    assert len(handler.calls) == 1
    assert handler.calls[0].app == "checkout"


def test_duplicate_revision_ignored(client: TestClient, handler: RecordingHandler) -> None:
    first = client.post("/hooks/argocd", json=hook_body(), headers=AUTH)
    second = client.post("/hooks/argocd", json=hook_body(), headers=AUTH)
    assert first.json()["status"] == "queued"
    assert second.status_code == 202
    assert second.json() == {"incident": f"checkout@{'a' * 40}", "status": "duplicate"}
    drain(client)
    assert len(handler.calls) == 1


def test_new_revision_is_a_new_incident(client: TestClient, handler: RecordingHandler) -> None:
    client.post("/hooks/argocd", json=hook_body(), headers=AUTH)
    r = client.post("/hooks/argocd", json=hook_body(revision="c" * 40), headers=AUTH)
    assert r.json()["status"] == "queued"
    drain(client)
    assert len(handler.calls) == 2


@pytest.mark.parametrize(
    "body",
    [
        b"not json at all",
        b"{}",
        b'{"app": "checkout"}',
        b'{"app": "checkout", "revision": 5}',
    ],
)
def test_malformed_body_422_not_retry_storm(client: TestClient, handler: RecordingHandler, body: bytes) -> None:
    r = client.post(
        "/hooks/argocd", content=body, headers={**AUTH, "Content-Type": "application/json"}
    )
    # A 4xx, so Argo Notifications does not retry; never a 5xx.
    assert r.status_code == 422
    drain(client)
    assert handler.calls == []


def test_unauthenticated_malformed_body_is_401_not_422(client: TestClient) -> None:
    r = client.post("/hooks/argocd", content=b"garbage", headers={"Content-Type": "application/json"})
    assert r.status_code == 401


def test_history_parsed(client: TestClient, handler: RecordingHandler) -> None:
    client.post("/hooks/argocd", json=hook_body(), headers=AUTH)
    drain(client)
    hook = handler.calls[0]
    assert [h.id for h in hook.history] == [1, 2]
    assert hook.history[1].revision == "a" * 40
    assert hook.history[0].deployedAt == datetime(2026, 11, 1, 10, 0, tzinfo=UTC)


def test_history_tolerates_extra_argo_fields() -> None:
    body = hook_body(
        history=[
            {
                "id": 7,
                "revision": "d" * 40,
                "deployedAt": "2026-11-02T10:00:00Z",
                "deployStartedAt": "2026-11-02T09:59:50Z",
                "source": {"repoURL": "https://example.invalid", "path": "apps/checkout"},
            }
        ]
    )
    hook = ArgoDegradedHook.model_validate(body)
    assert hook.history[0].revision == "d" * 40


def test_received_at_set_on_receipt(client: TestClient, handler: RecordingHandler) -> None:
    before = datetime.now(UTC)
    # A received_at in the body is ignored: the bridge sets it.
    client.post(
        "/hooks/argocd", json=hook_body(received_at="2001-01-01T00:00:00Z"), headers=AUTH
    )
    drain(client)
    after = datetime.now(UTC)
    received = handler.calls[0].received_at
    assert received is not None
    assert before <= received <= after


def test_handler_exception_does_not_kill_worker(settings: Settings) -> None:
    calls: list[str] = []

    async def flaky(hook: ArgoDegradedHook) -> None:
        calls.append(hook.revision)
        if len(calls) == 1:
            raise RuntimeError("boom")

    app = create_app(settings, handler=flaky)
    with TestClient(app) as c:
        c.post("/hooks/argocd", json=hook_body(), headers=AUTH)
        c.post("/hooks/argocd", json=hook_body(revision="c" * 40), headers=AUTH)
        drain(c)
    assert calls == ["a" * 40, "c" * 40]


def test_rehydrated_key_is_duplicate(settings: Settings, handler: RecordingHandler) -> None:
    app = create_app(settings, handler=handler)
    app.state.bridge.registry.rehydrate([f"checkout@{'a' * 40}"])
    with TestClient(app) as c:
        r = c.post("/hooks/argocd", json=hook_body(), headers=AUTH)
        assert r.json()["status"] == "duplicate"
        drain(c)
    assert handler.calls == []


def test_healthz(client: TestClient) -> None:
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.text == "ok"


def test_status_shape(client: TestClient) -> None:
    client.post("/hooks/argocd", json=hook_body(), headers=AUTH)
    drain(client)
    s = client.get("/status").json()
    assert set(s) == {
        "level_last_seen",
        "queue_depth",
        "last_incident",
        "holmes_reachable",
        "github_token_ok",
        "dry_forge",
    }
    assert s["queue_depth"] == 0
    assert s["last_incident"]["key"] == f"checkout@{'a' * 40}"
    assert s["dry_forge"] is False


def test_status_never_shows_token(client: TestClient) -> None:
    assert WEBHOOK_TOKEN not in client.get("/status").text


@pytest.mark.parametrize(
    "overrides",
    [
        {"revision": "x/../../issues/1"},
        {"sync_revision": "a" * 39 + "/"},
        {"sync_revision": "A" * 40},
        {"history": [{"id": 1, "revision": "../issues/1", "deployedAt": "2026-11-01T10:00:00Z"}]},
    ],
)
def test_non_sha_revisions_rejected_422(client: TestClient, handler: RecordingHandler, overrides: dict) -> None:
    r = client.post("/hooks/argocd", json=hook_body(**overrides), headers=AUTH)
    assert r.status_code == 422
    assert handler.calls == []
