"""Shared fixtures. No test in this suite talks to a real network service.

Network is off for the whole suite (spec 10): pytest-socket's `--disable-socket`
(set in pyproject's addopts) blocks every inet socket, and the autouse respx router
below makes any httpx request that no test route matches fail with
`AllMockedAssertionError` instead of trying the network. Unix sockets stay allowed
(`--allow-unix-socket`) because asyncio's event loop needs a socketpair.
"""

from __future__ import annotations

import logging

import pytest
import respx

from bridge.config import Settings

WEBHOOK_TOKEN = "test-webhook-token-not-a-secret"
# A test value: the real one comes from BRIDGE_EVENT_SOURCE in demo.env.
BRIDGE_SOURCE = "/test/bridge"


@pytest.fixture(autouse=True)
def _no_unmocked_http():
    """A catch-all respx router with no routes: an unmatched request raises.

    Tests that stub calls add their own `respx.mock` router; respx tries each
    router in turn, so their routes still answer.
    """
    with respx.mock(assert_all_mocked=True, assert_all_called=False) as router:
        yield router


class _Lines(logging.Handler):
    def __init__(self) -> None:
        super().__init__(logging.INFO)
        self.lines: list[str] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.lines.append(record.getMessage())


@pytest.fixture
def stage_lines():
    """Every stage line emitted during the test, in order.

    Attached to the `bridge.stage` logger itself: once the app's lifespan has run,
    that logger no longer propagates, so caplog can't see it.
    """
    logger = logging.getLogger("bridge.stage")
    handler, level = _Lines(), logger.level
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    yield handler.lines
    logger.removeHandler(handler)
    logger.setLevel(level)


@pytest.fixture
def settings() -> Settings:
    return Settings(
        webhook_token=WEBHOOK_TOKEN,
        github_repo="example-org/example-repo",
        tracked_branch="build/demo",
        holmes_url="http://holmes.test",
        holmes_api_key="holmes-test-key",
        cdevents_url="http://cdevents.test/events",
        bridge_event_source=BRIDGE_SOURCE,
        argo_ui_url="http://127.0.0.1:30080",
    )


def hook_body(**overrides: object) -> dict:
    """A webhook body shaped like the Argo Notifications template (Task 3.10)."""
    body: dict = {
        "app": "checkout",
        "namespace": "argocd",
        "revision": "a" * 40,
        "sync_revision": "a" * 40,
        "health": "Degraded",
        "history": [
            {"id": 1, "revision": "b" * 40, "deployedAt": "2026-11-01T10:00:00Z"},
            {"id": 2, "revision": "a" * 40, "deployedAt": "2026-11-02T10:00:00Z"},
        ],
        "repo_url": "https://github.com/example-org/example-repo",
        "target_revision": "build/demo",
    }
    body.update(overrides)
    return body
