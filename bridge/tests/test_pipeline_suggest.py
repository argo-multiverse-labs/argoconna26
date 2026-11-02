"""Task 3.9: the `suggest` pipeline with a FakeForge, a stub HolmesGPT and a recording emitter."""

from __future__ import annotations

import json
import re
from datetime import UTC, datetime

import pytest

from bridge import stagelog
from bridge.forge.fake import FakeForge
from bridge.holmes import HolmesBadOutput, HolmesResult, HolmesTimeout
from bridge.incidents import IncidentRegistry
from bridge.metrics import Metrics
from bridge.models import ArgoDegradedHook
from bridge.pipeline import Deps, Outcome, handle_incident
from bridge.rca import RCA

from .conftest import hook_body

BRANCH = "build/demo"
BASE = "1" * 40          # healthy deploy
CAUSE = "c" * 40         # PR-242 (re-arm): 2000 -> 200, no config-version bump
SYNC = "e" * 40          # the innocent image bump
CONFIG = "apps/checkout/config/checkout-config.yaml"
NOW = datetime(2026, 11, 9, 17, 42, 5, tzinfo=UTC)

AUTONOMY = """\
apiVersion: aiops.example.dev/v1
kind: Autonomy
level: suggest
since: "2026-11-02"
promotion: null
touchpoints: {suggest: 4, propose: 1, act: 1}
"""

CONFIGMAP = """\
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-config
data:
  UPSTREAM_TIMEOUT_MS: "200"
"""

MODEL_ROOT_CAUSE = "PR-242 cut UPSTREAM_TIMEOUT_MS to 200 without bumping config-version."
MODEL_CONTEXT = "CHG-7f3a merged 3 days before the abort as a config-only change."
EVIDENCE = [
    "Prometheus: pods started after the change report 200; older pods report 2000",
    "ConfigMap: checkout-config holds 200",
    "Rollout: canary aborted on the success-rate analysis",
    "AnalysisRun: success rate 0.62 below 0.99",
]


def rca(**overrides: object) -> RCA:
    data: dict = {
        "root_cause": MODEL_ROOT_CAUSE,
        "cause_commit_sha": CAUSE,
        "evidence": list(EVIDENCE),
        "delivery_context": MODEL_CONTEXT,
        "confidence": 0.9,
        "proposed_patch": {"file": CONFIG, "key": "UPSTREAM_TIMEOUT_MS", "from": "200", "to": "2000"},
    }
    data.update(overrides)
    return RCA.model_validate(data)


class StubHolmes:
    def __init__(self, result: RCA | BaseException, tool_calls: list[str] | None = None) -> None:
        self.result = result
        self.tool_calls = tool_calls if tool_calls is not None else ["GET /timeline", "prometheus range query"]
        self.prompts: list[str] = []

    async def investigate(self, prompt: str) -> HolmesResult:
        self.prompts.append(prompt)
        if isinstance(self.result, BaseException):
            raise self.result
        return HolmesResult(rca=self.result, tool_calls=self.tool_calls, raw_analysis="{}", latency_s=1.0)


class RecordingEmitter:
    def __init__(self, fail: bool = False) -> None:
        self.events: list[dict] = []
        self.fail = fail

    async def emit(self, event: dict) -> None:
        if self.fail:
            # A misbehaving emitter must not fail the incident either.
            raise RuntimeError("sink down")
        self.events.append(event)

    def types(self) -> list[str]:
        return [e["context"]["type"] for e in self.events]


def make_forge(**overrides: object) -> FakeForge:
    forge = FakeForge(
        files={("aiops/autonomy.yaml", BRANCH): AUTONOMY, (CONFIG, BRANCH): CONFIGMAP},
        commits=[BASE, CAUSE, SYNC],
        titles={CAUSE: "PR-242: tune upstream timeout for faster failover", SYNC: "checkout v1.4.2"},
    )
    for key, value in overrides.items():
        setattr(forge, key, value)
    return forge


def make_hook() -> ArgoDegradedHook:
    hook = ArgoDegradedHook.model_validate(
        hook_body(
            revision=SYNC,
            sync_revision=SYNC,
            history=[
                {"id": 1, "revision": BASE, "deployedAt": "2026-11-06T10:00:00Z"},
                {"id": 2, "revision": CAUSE, "deployedAt": "2026-11-06T11:00:00Z"},
                {"id": 3, "revision": SYNC, "deployedAt": "2026-11-09T17:40:00Z"},
            ],
        )
    )
    hook.received_at = NOW
    return hook


@pytest.fixture
def deps(settings):
    def build(holmes: StubHolmes | None = None, forge: FakeForge | None = None, emitter=None) -> Deps:
        return Deps(
            forge=forge or make_forge(),
            holmes=holmes or StubHolmes(rca()),
            emitter=emitter if emitter is not None else RecordingEmitter(),
            settings=settings,
            registry=IncidentRegistry(),
            clock=lambda: NOW,
            metrics=Metrics(),
        )

    return build


def posted(forge: FakeForge) -> list[str]:
    return [body for _, body in forge.commit_comments] + [body for _, body in forge.pr_comments]


async def test_suggest_comments_on_commit_when_no_pr(deps) -> None:
    d = deps()
    out = await handle_incident(make_hook(), d)
    assert out == Outcome("commented", "https://forge.test/commit/" + CAUSE + "#comment-1", level="suggest")
    assert [sha for sha, _ in d.forge.commit_comments] == [CAUSE]
    assert d.forge.pr_comments == []
    body = d.forge.commit_comments[0][1]
    assert body.startswith("## Root cause\n")
    assert MODEL_ROOT_CAUSE in body
    assert d.registry.seen(make_hook().key)


async def test_suggest_comments_on_pr_when_commit_has_pr(deps) -> None:
    d = deps(forge=make_forge(prs={CAUSE: [42]}))
    out = await handle_incident(make_hook(), d)
    assert out.action == "commented"
    assert [n for n, _ in d.forge.pr_comments] == [42]
    assert d.forge.commit_comments == []


async def test_refusal_posts_reason_and_counts_metric(deps) -> None:
    d = deps(holmes=StubHolmes(rca(confidence=0.4)))
    out = await handle_incident(make_hook(), d)
    assert out.action == "refused"
    [(sha, body)] = d.forge.commit_comments
    assert sha == CAUSE  # the cause checked out; only the confidence failed
    assert "low_confidence" in body
    assert "## Root cause" not in body
    assert d.metrics.value("aiops_guardrail_executions_total", reason="low_confidence") == 1
    assert d.metrics.value("aiops_actions_total", action="refused") == 1


async def test_refusal_with_unknown_cause_posts_on_synced_revision(deps) -> None:
    d = deps(holmes=StubHolmes(rca(cause_commit_sha="f" * 40)))
    out = await handle_incident(make_hook(), d)
    assert out.action == "refused"
    assert [sha for sha, _ in d.forge.commit_comments] == [SYNC]
    assert "cause_not_in_history" in d.forge.commit_comments[0][1]


async def test_pii_hit_blocks_model_text(deps) -> None:
    d = deps(holmes=StubHolmes(rca(root_cause="The canary at 10.244.1.7 timed out after a config change.")))
    out = await handle_incident(make_hook(), d)
    assert out.action == "pii_blocked"
    bodies = posted(d.forge)
    assert len(bodies) == 1
    for text in ("10.244.1.7", "timed out after a config change", MODEL_CONTEXT, *EVIDENCE):
        assert text not in bodies[0]
    assert d.metrics.value("aiops_pii_leaks_caught_total", kind="ipv4") == 1
    assert d.metrics.value("aiops_actions_total", action="pii_blocked") == 1


async def test_pii_hit_in_evidence_also_blocks(deps) -> None:
    d = deps(holmes=StubHolmes(rca(evidence=["Logs: request from ops@example.com failed"])))
    out = await handle_incident(make_hook(), d)
    assert out.action == "pii_blocked"
    assert "ops@example.com" not in posted(d.forge)[0]


async def test_pii_hit_suppresses_rca_event_text(deps) -> None:
    emitter = RecordingEmitter()
    d = deps(holmes=StubHolmes(rca(root_cause="The canary at 10.244.1.7 timed out.")), emitter=emitter)
    await handle_incident(make_hook(), d)
    assert "dev.cdeventsx.holmesgpt-rca.completed.0.1.0" not in emitter.types()
    assert "10.244.1.7" not in json.dumps(emitter.events)
    [event] = emitter.events
    assert event["context"]["type"] == "dev.cdeventsx.agent-action.0.1.0"
    assert event["customData"]["action"] == "pii_blocked"


async def test_pii_hit_in_refusal_blocks_too(deps) -> None:
    # A refused answer still sends model text: the RCA event carries root_cause.
    emitter = RecordingEmitter()
    d = deps(holmes=StubHolmes(rca(confidence=0.3, root_cause="Pushed by ops@example.com")), emitter=emitter)
    out = await handle_incident(make_hook(), d)
    assert out.action == "pii_blocked"
    assert "ops@example.com" not in json.dumps(posted(d.forge))
    assert "ops@example.com" not in json.dumps(emitter.events)
    assert d.metrics.value("aiops_guardrail_executions_total", reason="low_confidence") == 1


async def test_holmes_timeout_posts_handoff_without_model_text(deps, settings) -> None:
    d = deps(holmes=StubHolmes(HolmesTimeout("no answer within 115 s")))
    out = await handle_incident(make_hook(), d)
    assert out.action == "holmes_failed"
    assert d.forge.commit_comments == [
        (SYNC, f"Investigation did not finish in {settings.holmes_timeout_s:g} s; a human should take this one.")
    ]
    assert d.metrics.value("aiops_actions_total", action="holmes_failed") == 1


async def test_holmes_bad_output_posts_handoff(deps) -> None:
    d = deps(holmes=StubHolmes(HolmesBadOutput("analysis is not JSON")))
    out = await handle_incident(make_hook(), d)
    assert out.action == "holmes_failed"
    [(sha, body)] = d.forge.commit_comments
    assert sha == SYNC
    assert "a human should take this one" in body
    assert "analysis is not JSON" not in body


async def test_failsafe_level_used_when_autonomy_unreadable(deps, stage_lines: list[str]) -> None:
    forge = make_forge()
    del forge.files[("aiops/autonomy.yaml", BRANCH)]
    d = deps(forge=forge)
    out = await handle_incident(make_hook(), d)
    assert out.action == "commented"
    assert out.level == "suggest"
    assert "▸ autonomy: fail-safe suggest" in stage_lines
    assert d.metrics.value("aiops_incidents_total", level="suggest") == 1


@pytest.mark.parametrize("level", ["act"])
async def test_act_not_implemented_before_task_5_4(deps, level: str) -> None:
    forge = make_forge()
    forge.files[("aiops/autonomy.yaml", BRANCH)] = AUTONOMY.replace("level: suggest", f"level: {level}")
    d = deps(forge=forge)
    with pytest.raises(NotImplementedError):
        await handle_incident(make_hook(), d)
    assert posted(d.forge) == []


async def test_rca_event_emitted(deps) -> None:
    emitter = RecordingEmitter()
    d = deps(emitter=emitter)
    await handle_incident(make_hook(), d)
    rca_events = [e for e in emitter.events if e["context"]["type"] == "dev.cdeventsx.holmesgpt-rca.completed.0.1.0"]
    assert len(rca_events) == 1
    cd = rca_events[0]["customData"]
    assert cd["cause_commit_sha"] == CAUSE
    assert cd["level"] == "suggest"
    assert cd["root_cause"] == MODEL_ROOT_CAUSE


async def test_emitter_failure_does_not_fail_incident(deps) -> None:
    d = deps(emitter=RecordingEmitter(fail=True))
    out = await handle_incident(make_hook(), d)
    assert out.action == "commented"
    assert len(d.forge.commit_comments) == 1


async def test_comment_has_at_most_three_evidence_bullets(deps) -> None:
    d = deps()
    await handle_incident(make_hook(), d)
    body = d.forge.commit_comments[0][1]
    bullets = [line for line in body.splitlines() if line.startswith("- ")]
    assert 1 <= len(bullets) <= 3
    assert EVIDENCE[3] not in body


async def test_comment_contains_delivery_context_bullet(deps) -> None:
    d = deps()
    await handle_incident(make_hook(), d)
    body = d.forge.commit_comments[0][1]
    assert f"- Timeline: {MODEL_CONTEXT}" in body.splitlines()


@pytest.mark.parametrize("prefix", ["Timeline: ", "timeline:", "  TIMELINE :  ", "Timeline - "])
async def test_delivery_context_timeline_prefix_not_doubled(deps, prefix: str) -> None:
    d = deps(holmes=StubHolmes(rca(delivery_context=prefix + MODEL_CONTEXT)))
    await handle_incident(make_hook(), d)
    body = d.forge.commit_comments[0][1]
    assert f"- Timeline: {MODEL_CONTEXT}" in body.splitlines()


async def test_delivery_context_that_mentions_the_timeline_later_is_kept(deps) -> None:
    text = "CHG-7f3a is the only change on the timeline: config-only."
    d = deps(holmes=StubHolmes(rca(delivery_context=text)))
    await handle_incident(make_hook(), d)
    assert f"- Timeline: {text}" in d.forge.commit_comments[0][1].splitlines()


async def test_comment_cause_line_is_full_sha(deps) -> None:
    d = deps(holmes=StubHolmes(rca(cause_commit_sha=CAUSE[:7].upper())))
    await handle_incident(make_hook(), d)
    body = d.forge.commit_comments[0][1]
    assert re.search(r"^Cause: [0-9a-f]{40}\b", body, re.MULTILINE)
    assert f"Cause: {CAUSE} (PR-242: tune upstream timeout for faster failover)" in body.splitlines()


async def test_comment_states_the_human_fix_and_argo_link(deps, settings) -> None:
    d = deps()
    await handle_incident(make_hook(), d)
    body = d.forge.commit_comments[0][1]
    assert (
        f"**What a human should do:** {CONFIG} UPSTREAM_TIMEOUT_MS 200 → 2000, and bump config-version"
        in body.splitlines()
    )
    assert f"{settings.argo_ui_url}/applications/argocd/checkout" in body


async def test_model_text_cannot_mention_people(deps) -> None:
    d = deps(holmes=StubHolmes(rca(root_cause="Ask @payments-team about the change.")))
    await handle_incident(make_hook(), d)
    body = d.forge.commit_comments[0][1]
    assert "@payments-team" not in body  # no notification from a public repo comment


async def test_touchpoints_metric_from_autonomy(deps) -> None:
    d = deps()
    await handle_incident(make_hook(), d)
    assert d.metrics.value("aiops_human_touchpoints", level="suggest") == 4
    assert d.metrics.value("aiops_human_touchpoints", level="propose") == 1
    assert d.metrics.value("aiops_human_touchpoints", level="act") == 1


async def test_refusal_and_comment_emit_agent_action_events(deps) -> None:
    for model, action in ((rca(), "commented"), (rca(confidence=0.1), "refused")):
        emitter = RecordingEmitter()
        d = deps(holmes=StubHolmes(model), emitter=emitter)
        out = await handle_incident(make_hook(), d)
        actions = [e for e in emitter.events if e["context"]["type"] == "dev.cdeventsx.agent-action.0.1.0"]
        assert len(actions) == 1
        cd = actions[0]["customData"]
        assert cd["action"] == action
        assert cd["target_url"] == out.url
        assert cd["app"] == "checkout"
        assert cd["level"] == "suggest"
    assert cd["reason"] == "low_confidence"


async def test_holmes_failure_emits_agent_action_only(deps) -> None:
    emitter = RecordingEmitter()
    d = deps(holmes=StubHolmes(HolmesTimeout("x")), emitter=emitter)
    await handle_incident(make_hook(), d)
    assert emitter.types() == ["dev.cdeventsx.agent-action.0.1.0"]
    assert emitter.events[0]["customData"]["action"] == "holmes_failed"
    assert emitter.events[0]["customData"]["reason"] == "timeout"


async def test_bridge_events_carry_bridge_source(deps, settings) -> None:
    emitter = RecordingEmitter()
    await handle_incident(make_hook(), deps(emitter=emitter))
    assert emitter.events
    assert {e["context"]["source"] for e in emitter.events} == {settings.bridge_event_source}


async def test_several_tool_calls_including_errors_are_staged(deps, stage_lines: list[str]) -> None:
    # O14: several tool calls per investigation, some failing, are normal.
    calls = ["timeline request (refused)", "GET /events (refused)", "GET /timeline", "GET /timeline"]
    d = deps(holmes=StubHolmes(rca(), tool_calls=calls))
    out = await handle_incident(make_hook(), d)
    assert out.action == "commented"
    holmes_lines = [line for line in stage_lines if line.startswith("▸ holmes:")]
    cols = d.settings.stage_cols
    assert holmes_lines == [stagelog.line("holmes", "investigating", cols)] + [
        stagelog.line("holmes", call, cols) for call in calls
    ]
    for line in stage_lines:
        assert len(line) <= d.settings.stage_cols


async def test_stage_lines_carry_no_sha(deps, stage_lines: list[str]) -> None:
    await handle_incident(make_hook(), deps())
    stage = stage_lines
    assert any(line.startswith("▸ autonomy: suggest") for line in stage)
    assert any(line.startswith("▸ suggest: comment") for line in stage)
    for line in stage:
        assert not re.search(r"[0-9a-f]{7,}", line), line


async def test_prompt_anchored_to_received_at(deps) -> None:
    holmes = StubHolmes(rca())
    await handle_incident(make_hook(), deps(holmes=holmes))
    [prompt] = holmes.prompts
    assert "2026-11-09T17:32:05Z" in prompt and "2026-11-09T17:43:05Z" in prompt
