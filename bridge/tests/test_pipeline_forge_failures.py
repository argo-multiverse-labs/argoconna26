"""A failed forge write still leaves a trace: an outcome, an event, a metric and a stage line."""

from __future__ import annotations

import pytest

from bridge.forge import ForgeError
from bridge.holmes import HolmesTimeout
from bridge.pipeline import handle_incident, outcome_for_status

from .test_pipeline_suggest import RecordingEmitter, StubHolmes, deps, make_forge, make_hook, rca  # noqa: F401  (deps is a fixture)


def failing_forge():
    return make_forge(fail_writes=ForgeError("POST /commits/x/comments: 403", 403))


def actions(emitter: RecordingEmitter) -> list[dict]:
    return [e["customData"] for e in emitter.events if e["context"]["type"].endswith("agent-action.completed.0.1.0")
            or "action" in (e.get("customData") or {})]


@pytest.mark.parametrize(
    ("holmes", "intended"),
    [
        (StubHolmes(rca()), "commented"),
        (StubHolmes(rca(confidence=0.4)), "refused"),
        (StubHolmes(rca(root_cause="seen at 10.244.1.7")), "pii_blocked"),
        (StubHolmes(HolmesTimeout("slow")), "holmes_failed"),
    ],
)
async def test_forge_write_failure_is_recorded(deps, stage_lines, holmes, intended) -> None:
    emitter = RecordingEmitter()
    d = deps(holmes=holmes, forge=failing_forge(), emitter=emitter)
    out = await handle_incident(make_hook(), d)
    assert out.action == intended
    assert out.url is None
    assert out.post_failed is True
    status = outcome_for_status(out)
    assert status["post_failed"] is True
    assert status["holmes_failed"] is (intended == "holmes_failed")
    [act] = [c for c in actions(emitter) if c.get("action") == "post_failed"]
    assert act["reason"] == intended
    assert act["target_url"] is None
    assert d.metrics.value("aiops_actions_total", action="post_failed") == 1
    assert d.metrics.value("aiops_actions_total", action=intended) == 0
    assert any("post failed" in line for line in stage_lines)


async def test_successful_post_is_not_marked_failed(deps) -> None:
    out = await handle_incident(make_hook(), deps())
    assert out.post_failed is False
    assert outcome_for_status(out)["post_failed"] is False
