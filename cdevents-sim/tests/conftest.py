from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from cdevents_sim.store import Store

BRIDGE_SOURCE = "/argoconna26/bridge"
NOW = datetime(2026, 11, 2, 12, 0, 0, tzinfo=timezone.utc)


def ts(minutes_ago: float = 0, now: datetime | None = None) -> str:
    base = now or datetime.now(timezone.utc)
    return (base - timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _argocd_data(app: str, revision: str) -> dict:
    return {"argocd": {"application": app, "revision": revision}}


def service_deployed(cid="evt-1", app="checkout", revision="a" * 40, when=None) -> dict:
    return {
        "context": {
            "specversion": "0.5.1",
            "id": cid,
            "source": "/argocd/argocd",
            "type": "dev.cdevents.service.deployed.0.3.0",
            "timestamp": when or ts(),
        },
        "subject": {
            "id": f"demo/{app}",
            "source": "/argocd/argocd",
            "content": {
                "environment": {"id": "demo"},
                "artifactId": f"pkg:generic/{app}@{revision}",
            },
        },
        "customData": _argocd_data(app, revision),
    }


def incident(kind: str, cid: str, app="checkout", revision="b" * 40, when=None) -> dict:
    assert kind in ("detected", "resolved")
    return {
        "context": {
            "specversion": "0.5.1",
            "id": cid,
            "source": "/argocd/argocd",
            "type": f"dev.cdevents.incident.{kind}.0.3.0",
            "timestamp": when or ts(),
        },
        "subject": {
            "id": f"demo/{app}/incident/{revision}",
            "source": "/argocd/argocd",
            "content": {
                "environment": {"id": "demo"},
                "service": {"id": f"demo/{app}"},
                "artifactId": f"pkg:generic/{app}@{revision}",
            },
        },
        "customData": _argocd_data(app, revision),
    }


def change_merged(cid="chg-1", app="checkout", sha="c" * 40, source="/forge/github", when=None, custom=None) -> dict:
    return {
        "context": {
            "specversion": "0.5.1",
            "id": cid,
            "source": source,
            "type": "dev.cdevents.change.merged.0.3.0",
            "timestamp": when or ts(),
        },
        "subject": {
            "id": sha,
            "source": source,
            "content": {"repository": {"id": "argo-multiverse-labs/argoconna26"}},
        },
        "customData": {"app": app, "revision": sha, **(custom or {})},
    }


def change_created(cid="chg-c", app="checkout", source=BRIDGE_SOURCE, when=None) -> dict:
    e = change_merged(cid=cid, app=app, source=source, when=when)
    e["context"]["type"] = "dev.cdevents.change.created.0.4.0"
    return e


def custom_event(typ: str, cid: str, app="checkout", source=BRIDGE_SOURCE, when=None, custom=None) -> dict:
    return {
        "context": {"id": cid, "source": source, "type": typ, "timestamp": when or ts()},
        "subject": {"id": f"demo/{app}"},
        "customData": {"app": app, **(custom or {})},
    }


@pytest.fixture
def store(tmp_path):
    return Store(tmp_path / "events.jsonl", bridge_source=BRIDGE_SOURCE)
