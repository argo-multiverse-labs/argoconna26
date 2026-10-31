"""Shared fixtures. No test in this suite talks to a real network service."""

from __future__ import annotations

import pytest

from bridge.config import Settings

WEBHOOK_TOKEN = "test-webhook-token-not-a-secret"


@pytest.fixture
def settings() -> Settings:
    return Settings(
        webhook_token=WEBHOOK_TOKEN,
        github_repo="example-org/example-repo",
        tracked_branch="build/demo",
        holmes_url="http://holmes.test",
        holmes_api_key="holmes-test-key",
        cdevents_url="http://cdevents.test/events",
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
