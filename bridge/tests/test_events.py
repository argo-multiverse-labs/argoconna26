"""Task 3.9: the bridge's own CDEvents (spec 7.1: every agent action is on the timeline)."""

from __future__ import annotations

import json
import logging
import os
from datetime import UTC, datetime
from pathlib import Path

import httpx
import pytest
import respx
from jsonschema import Draft202012Validator

from bridge import events
from bridge.models import ArgoDegradedHook
from bridge.rca import RCA

from .conftest import BRIDGE_SOURCE, hook_body

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_DIR = Path(os.environ.get("CDEVENTS_SCHEMA_DIR", REPO_ROOT / "cdevents-sim" / "schemas" / "v0.5.1"))
NOW = datetime(2026, 11, 9, 17, 42, 5, tzinfo=UTC)
SINK = "http://cdevents.test/events"

RCA_DATA = {
    "root_cause": "PR-242 set UPSTREAM_TIMEOUT_MS to 200 without a config-version bump.",
    "cause_commit_sha": "c" * 40,
    "evidence": ["Prometheus: pods started after the change report 200"],
    "delivery_context": "CHG-1 merged 3 days before the abort",
    "confidence": 0.9,
    "proposed_patch": {
        "file": "apps/checkout/config/checkout-config.yaml",
        "key": "UPSTREAM_TIMEOUT_MS",
        "from": "200",
        "to": "2000",
    },
}


def _hook() -> ArgoDegradedHook:
    return ArgoDegradedHook.model_validate(hook_body())


def _validate_standard(event: dict) -> None:
    """Validate a standard CDEvent against its vendored v0.5.1 schema."""
    _, subject, predicate = event["context"]["type"].split(".")[:4][1:]
    schema = json.loads((SCHEMA_DIR / f"{subject}{predicate}.json").read_text())
    errors = list(Draft202012Validator(schema).iter_errors(event))
    assert errors == [], [e.message for e in errors]


def test_rca_completed_shape() -> None:
    event = events.rca_completed(_hook(), RCA.model_validate(RCA_DATA), "suggest", source=BRIDGE_SOURCE, now=NOW)
    assert event["context"]["type"] == "dev.cdeventsx.holmesgpt-rca.completed.0.1.0"
    assert event["context"]["timestamp"] == "2026-11-09T17:42:05Z"
    cd = event["customData"]
    assert cd["root_cause"] == RCA_DATA["root_cause"]
    assert cd["cause_commit_sha"] == "c" * 40
    assert cd["confidence"] == 0.9
    assert cd["level"] == "suggest"
    # The sim attributes the incident's level by app (cdevents-sim store).
    assert cd["app"] == "checkout"


def test_agent_action_shape() -> None:
    event = events.agent_action(
        "refused", "https://forge.test/c#1", reason="low_confidence", source=BRIDGE_SOURCE,
        app="checkout", level="suggest", revision="a" * 40, now=NOW,
    )
    assert event["context"]["type"] == "dev.cdeventsx.agent-action.0.1.0"
    cd = event["customData"]
    assert cd == {
        "action": "refused",
        "target_url": "https://forge.test/c#1",
        "reason": "low_confidence",
        "app": "checkout",
        "level": "suggest",
        "revision": "a" * 40,
    }


def test_change_created_type_and_schema() -> None:
    event = events.change_created(
        "https://github.com/o/r/pull/7", "agent/fix-checkout", "o/r", source=BRIDGE_SOURCE, now=NOW
    )
    assert event["context"]["type"] == "dev.cdevents.change.created.0.4.0"
    _validate_standard(event)


def test_change_merged_type_is_0_3_0_and_schema() -> None:
    # O1: CDEvents v0.5.1 defines change.merged 0.3.0; only change.created is 0.4.0.
    event = events.change_merged(
        "https://github.com/o/r/pull/7", "d" * 40, "argoconna26-agent[bot]", source=BRIDGE_SOURCE, now=NOW
    )
    assert event["context"]["type"] == "dev.cdevents.change.merged.0.3.0"
    _validate_standard(event)


def test_bridge_events_carry_bridge_source() -> None:
    hook, rca = _hook(), RCA.model_validate(RCA_DATA)
    built = [
        events.rca_completed(hook, rca, "suggest", source=BRIDGE_SOURCE),
        events.agent_action("commented", "u", source=BRIDGE_SOURCE),
        events.change_created("u", "b", "o/r", source=BRIDGE_SOURCE),
        events.change_merged("u", "d" * 40, "bot", source=BRIDGE_SOURCE),
    ]
    for event in built:
        assert event["context"]["source"] == BRIDGE_SOURCE
        assert event["context"]["id"]
    assert len({e["context"]["id"] for e in built}) == len(built)


@respx.mock(assert_all_mocked=True)
async def test_emitter_posts_event(respx_mock) -> None:
    route = respx_mock.post(SINK).mock(return_value=httpx.Response(202, json={"id": "x"}))
    event = events.agent_action("commented", "u", source=BRIDGE_SOURCE)
    async with httpx.AsyncClient() as http:
        await events.CDEventsEmitter(SINK, http=http).emit(event)
    assert json.loads(route.calls[0].request.content) == event


@pytest.mark.parametrize(
    "response",
    [httpx.Response(500), httpx.Response(400, json={"reason": "bad"}), httpx.ConnectError("down")],
)
@respx.mock(assert_all_mocked=True)
async def test_emitter_never_raises(respx_mock, response, caplog: pytest.LogCaptureFixture) -> None:
    if isinstance(response, Exception):
        respx_mock.post(SINK).mock(side_effect=response)
    else:
        respx_mock.post(SINK).mock(return_value=response)
    caplog.set_level(logging.WARNING, logger="bridge.events")
    async with httpx.AsyncClient() as http:
        await events.CDEventsEmitter(SINK, http=http).emit(events.agent_action("commented", "u", source=BRIDGE_SOURCE))
    assert "event not delivered" in caplog.text


@respx.mock(assert_all_mocked=True)
async def test_emitter_without_url_or_source_drops(respx_mock) -> None:
    async with httpx.AsyncClient() as http:
        await events.CDEventsEmitter("", http=http).emit(events.agent_action("commented", "u", source=BRIDGE_SOURCE))
        # An event without the bridge's source would leak onto /timeline (P16): fail closed.
        await events.CDEventsEmitter(SINK, http=http).emit(events.agent_action("commented", "u", source=""))
    assert respx_mock.calls.call_count == 0


async def test_null_emitter_drops_everything() -> None:
    emitter = events.NullEmitter()
    await emitter.emit(events.agent_action("commented", "u", source=BRIDGE_SOURCE))
