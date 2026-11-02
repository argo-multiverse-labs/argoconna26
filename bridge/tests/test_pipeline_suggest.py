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


# -- projector length (slice-3 C6): the rung-1 comment is capped like the fix PR body -------

LONG_ROOT = (
    "PR-242 cut UPSTREAM_TIMEOUT_MS from 2000 to 200 in checkout-config.yaml without bumping "
    "example.dev/config-version, so the running pods kept the old value until the next roll and "
    "nobody noticed for three days because nothing restarted. When the image bump rolled the "
    "canary, the new pods read 200 ms."
)
LONG_PODS = (
    "Pods checkout-7f9c8d6b5-x2x9k, checkout-7f9c8d6b5-q8w2n, checkout-7f9c8d6b5-zz7lp and "
    "checkout-7f9c8d6b5-m4k1c started after the sync and log 'upstream timeout after 200ms', "
    "while checkout-6d8b7c9f4-a1b2c and checkout-6d8b7c9f4-d3e4f started before it and log 2000"
)
LONG_CONTEXT_REF_LATE = (
    "The cause merged three days before the abort as a config-only change with no config-version "
    "bump, was synced by Argo CD without rolling any pods, and was then picked up when the image "
    "bump rolled the canary; its change reference is CHG-R6723Q"
)


def comment_body(d: Deps) -> str:
    [(_, body)] = d.forge.commit_comments
    return body


def bullets(body: str) -> list[str]:
    return [line for line in body.splitlines() if line.startswith("- ")]


async def test_comment_caps_root_cause_and_evidence_for_the_projector(deps) -> None:
    from bridge.pipeline import ITEM_MAX, ROOT_CAUSE_MAX

    d = deps(holmes=StubHolmes(rca(root_cause=LONG_ROOT, evidence=[LONG_PODS, LONG_PODS],
                                   delivery_context=LONG_PODS)))
    out = await handle_incident(make_hook(), d)
    assert out.action == "commented"
    body = comment_body(d)
    root_text = body.split("\n\n")[1]
    assert root_text.startswith("PR-242 cut")
    assert "When the image bump" not in root_text  # first sentence only
    assert len(root_text) <= ROOT_CAUSE_MAX + 10  # a few backslash escapes at most
    lines = bullets(body)
    assert len(lines) == 3
    for line in lines:
        assert len(line) <= ITEM_MAX + len("- Timeline: ") + 10, line
        assert line.endswith("…"), line
    assert any(line.startswith(f"Cause: {CAUSE}") for line in body.splitlines())


async def test_comment_timeline_keeps_change_ref_when_capped(deps) -> None:
    """tests/e2e/rung1.sh greps the `- Timeline:` line for the run's change_ref."""
    from bridge.pipeline import ITEM_MAX

    d = deps(holmes=StubHolmes(rca(delivery_context=LONG_CONTEXT_REF_LATE)))
    await handle_incident(make_hook(), d)
    [timeline] = [line for line in bullets(comment_body(d)) if line.startswith("- Timeline: ")]
    assert "CHG-R6723Q" in timeline
    assert len(timeline) <= ITEM_MAX + len("- Timeline: "), timeline


async def test_comment_timeline_keeps_change_ref_from_a_later_sentence(deps) -> None:
    d = deps(holmes=StubHolmes(rca(delivery_context="Config-only change, merged 3 days ago. Ref CHG-W4M4C4.")))
    await handle_incident(make_hook(), d)
    [timeline] = [line for line in bullets(comment_body(d)) if line.startswith("- Timeline: ")]
    assert "CHG-W4M4C4" in timeline


async def test_comment_timeline_short_context_unchanged(deps) -> None:
    d = deps()
    await handle_incident(make_hook(), d)
    assert f"- Timeline: {MODEL_CONTEXT}" in comment_body(d).splitlines()


@pytest.mark.parametrize("label", ["Timeline ", "timeline\t", "TIMELINE - ", "Timeline-"])
def test_timeline_label_word_without_colon_is_stripped(label: str) -> None:
    from bridge.pipeline import timeline_text

    out = timeline_text(label + "change CHG-KBMAEZ merged at 10:02.")
    assert out == "change CHG-KBMAEZ merged at 10:02."


def test_timeline_word_that_is_part_of_another_word_is_kept() -> None:
    from bridge.pipeline import timeline_text

    assert timeline_text("Timelines show CHG-KBMAEZ.") == "Timelines show CHG-KBMAEZ."


def test_timeline_never_appends_a_second_unrelated_change_ref() -> None:
    from bridge.pipeline import ITEM_MAX, timeline_text

    text = (
        "Timeline change CHG-KBMAEZ (bcea2c6, " + "tune upstream timeout and roll config " * 6
        + ") merged at 10:02. An earlier bump CHG-2SLM3T was unrelated."
    )
    out = timeline_text(text)
    assert "CHG-KBMAEZ" in out
    assert "CHG-2SLM3T" not in out
    assert len(out) <= ITEM_MAX


def test_timeline_appends_only_the_first_ref_when_the_cut_drops_it() -> None:
    from bridge.pipeline import timeline_text

    out = timeline_text("Config-only change, merged 3 days ago. Ref CHG-W4M4C4, not CHG-2SLM3T.")
    assert "CHG-W4M4C4" in out
    assert "CHG-2SLM3T" not in out


# -- O25 timeline follow-ups (review 11-02): "Timeline of ..." and the cause's own change_ref ----


@pytest.mark.parametrize("text", [
    "Timeline of events: CHG-KBMAEZ merged at 10:02.",
    "Timeline for checkout: CHG-KBMAEZ merged at 10:02.",
    "Timeline is short: CHG-KBMAEZ merged at 10:02.",
])
def test_timeline_word_that_starts_a_phrase_is_kept(text: str) -> None:
    from bridge.pipeline import timeline_text

    assert timeline_text(text) == text


@pytest.mark.parametrize("label", ["Timeline ", "Timeline CHG-", "Timeline 8312067"])
def test_bare_timeline_label_before_content_is_stripped(label: str) -> None:
    from bridge.pipeline import timeline_text

    rest = {"Timeline ": "change CHG-KBMAEZ merged.", "Timeline CHG-": "CHG-KBMAEZ merged.",
            "Timeline 8312067": "8312067 (CHG-KBMAEZ) merged."}[label]
    assert timeline_text("Timeline " + rest) == rest


def test_timeline_keeps_only_the_cause_ref_and_drops_the_others() -> None:
    from bridge.pipeline import timeline_text

    text = "CHG-AAAAAA (old rearm) and CHG-KBMAEZ (8312067) both tuned the timeout; the latter merged at 10:02."
    out = timeline_text(text, cause_ref="CHG-KBMAEZ")
    assert "CHG-KBMAEZ" in out
    assert "CHG-AAAAAA" not in out
    assert out.count("CHG-") == 1


def test_timeline_appends_the_cause_ref_when_the_model_named_a_wrong_one() -> None:
    from bridge.pipeline import ITEM_MAX, timeline_text

    out = timeline_text("Config-only change CHG-AAAAAA merged 3 days ago.", cause_ref="CHG-KBMAEZ")
    assert out.endswith("(CHG-KBMAEZ)")
    assert "CHG-AAAAAA" not in out and len(out) <= ITEM_MAX


def test_timeline_appends_the_cause_ref_when_the_model_named_none() -> None:
    from bridge.pipeline import timeline_text

    assert timeline_text("Config-only change merged 3 days ago.", cause_ref="CHG-KBMAEZ") == (
        "Config-only change merged 3 days ago. (CHG-KBMAEZ)")


class StubChangeRefs:
    def __init__(self, ref: str | None) -> None:
        self.ref = ref
        self.calls: list[tuple[str, str]] = []

    async def change_ref(self, app: str, sha: str) -> str | None:
        self.calls.append((app, sha))
        return self.ref


async def test_comment_timeline_uses_the_cause_commits_change_ref(deps) -> None:
    d = deps(holmes=StubHolmes(rca(delivery_context="CHG-AAAAAA merged 3 days before the abort.")))
    refs = StubChangeRefs("CHG-KBMAEZ")
    d.change_refs = refs
    await handle_incident(make_hook(), d)
    [timeline] = [line for line in bullets(comment_body(d)) if line.startswith("- Timeline: ")]
    assert "CHG-KBMAEZ" in timeline and "CHG-AAAAAA" not in timeline
    assert refs.calls == [("checkout", CAUSE)]


async def test_comment_timeline_without_a_lookup_keeps_the_model_text(deps) -> None:
    d = deps()
    d.change_refs = StubChangeRefs(None)
    await handle_incident(make_hook(), d)
    assert f"- Timeline: {MODEL_CONTEXT}" in comment_body(d).splitlines()


async def test_sim_change_refs_finds_the_ref_for_the_cause(_no_unmocked_http) -> None:
    import httpx
    import respx

    from bridge.events import SimChangeRefs

    rows = [
        {"type": "dev.cdevents.change.merged.0.3.0", "revision": "d" * 40, "customData": {"change_ref": "CHG-AAAAAA"}},
        {"type": "dev.cdevents.change.merged.0.3.0", "revision": CAUSE, "customData": {"change_ref": "CHG-KBMAEZ"}},
        {"type": "dev.cdevents.change.merged.0.3.0", "revision": CAUSE, "customData": {"change_ref": "not-a-ref"}},
    ]
    with respx.mock(assert_all_called=True) as r:
        route = r.get("http://sim.test/events").mock(return_value=httpx.Response(200, json=rows))
        async with httpx.AsyncClient() as http:
            got = await SimChangeRefs("http://sim.test/events", http=http).change_ref("checkout", CAUSE)
    assert got == "CHG-KBMAEZ"
    params = route.calls[0].request.url.params
    assert params["app"] == "checkout" and params["type"].startswith("dev.cdevents.change.merged")


@pytest.mark.parametrize("response", [500, "boom", [{"revision": "d" * 40, "customData": {"change_ref": "CHG-AAAAAA"}}]])
async def test_sim_change_refs_none_when_unknown_or_unreachable(_no_unmocked_http, response) -> None:
    import httpx
    import respx

    from bridge.events import SimChangeRefs

    with respx.mock() as r:
        route = r.get("http://sim.test/events")
        if response == 500:
            route.mock(return_value=httpx.Response(500))
        elif response == "boom":
            route.mock(side_effect=httpx.ConnectError("down"))
        else:
            route.mock(return_value=httpx.Response(200, json=response))
        async with httpx.AsyncClient() as http:
            assert await SimChangeRefs("http://sim.test/events", http=http).change_ref("checkout", CAUSE) is None


async def test_sim_change_refs_without_url_is_none() -> None:
    from bridge.events import SimChangeRefs

    assert await SimChangeRefs("").change_ref("checkout", CAUSE) is None


def test_timeline_label_given_twice_is_stripped_twice() -> None:
    from bridge.pipeline import timeline_text

    assert timeline_text("Timeline: Timeline change CHG-KBMAEZ merged.") == "change CHG-KBMAEZ merged."


async def test_suggest_ignores_pr_not_merged_into_tracked_branch(deps) -> None:
    """An open test PR that happens to contain the cause commit never gets the RCA comment."""
    d = deps(forge=make_forge(prs={CAUSE: [42]}, unmerged_prs={42}))
    out = await handle_incident(make_hook(), d)
    assert out.action == "commented"
    assert d.forge.pr_comments == []
    assert [sha for sha, _ in d.forge.commit_comments] == [CAUSE]
    assert ("prs_for_commit", CAUSE, d.settings.tracked_branch) in d.forge.calls
