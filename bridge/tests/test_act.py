"""Task 5.4: the `act` pipeline. The propose steps, then policy-gated auto-merge.

`enable_auto_merge` normally returns `enabled` while `policy-check` is still pending (the
required check holds the merge). When GitHub refuses because the PR is already mergeable
(`clean_status`: no required check yet, O25), the bridge polls the check itself and merges
only on `success`. A failing check is left for the reconciler, which comments once.
"""

from __future__ import annotations

import pytest

from bridge import events
from bridge.forge import ForgeError
from bridge.forge.fake import FakeForge
from bridge.incidents import IncidentRegistry
from bridge.metrics import Metrics
from bridge.pipeline import Deps, handle_incident
from bridge.reconcile import Reconciler

from .test_pipeline_suggest import (
    AUTONOMY,
    BRANCH,
    NOW,
    RecordingEmitter,
    StubHolmes,
    make_hook,
    rca,
)
from .test_propose import BRANCH_NAME, propose_forge, sections

ACT_AUTONOMY = AUTONOMY.replace("level: suggest", "level: act")


class Sleeper:
    """Stands in for asyncio.sleep: records each wait and returns at once."""

    def __init__(self) -> None:
        self.waits: list[float] = []

    async def __call__(self, seconds: float) -> None:
        self.waits.append(seconds)


def act_forge(**overrides: object) -> FakeForge:
    forge = propose_forge(**overrides)
    forge.files[("aiops/autonomy.yaml", BRANCH)] = ACT_AUTONOMY
    return forge


@pytest.fixture
def deps(settings):
    def build(forge: FakeForge | None = None, emitter=None, registry: IncidentRegistry | None = None) -> Deps:
        return Deps(
            forge=forge or act_forge(),
            holmes=StubHolmes(rca()),
            emitter=emitter if emitter is not None else RecordingEmitter(),
            settings=settings,
            registry=registry if registry is not None else IncidentRegistry(),  # an empty registry is falsy
            clock=lambda: NOW,
            metrics=Metrics(),
            sleep=Sleeper(),
        )

    return build


async def run(deps, forge: FakeForge | None = None, emitter=None, registry=None):
    d = deps(forge=forge, emitter=emitter, registry=registry)
    out = await handle_incident(make_hook(), d)
    return d, out


def head(forge: FakeForge) -> str:
    [opened] = forge.opened
    return opened.pr.head_sha


def calls(forge: FakeForge, name: str) -> list[tuple]:
    return [c for c in forge.calls if c[0] == name]


def actions(emitter: RecordingEmitter) -> list[str]:
    return [e["customData"]["action"] for e in emitter.events if e["context"]["type"] == events.AGENT_ACTION]


# -- the enabled path ----------------------------------------------------------


async def test_act_enables_auto_merge(deps) -> None:
    d, out = await run(deps)
    forge = d.forge
    [opened] = forge.opened
    assert opened.branch == BRANCH_NAME
    assert forge.auto_merges == [(opened.pr.number, "merge")]
    assert out.action == "auto_merge_enabled"
    assert out.level == "act"
    assert out.url == opened.pr.url
    # The fake's check never reports, so GitHub's auto-merge is left to do the merge.
    assert forge.merged == []
    assert calls(forge, "merge_pr") == []
    assert d.metrics.value("aiops_actions_total", action="pr_opened") == 1
    assert d.metrics.value("aiops_actions_total", action="auto_merge_enabled") == 1


async def test_act_stage_lines_fit_and_carry_no_sha(deps, stage_lines: list[str]) -> None:
    forge = act_forge(auto_merge="clean_status", check_runs={})
    d = deps(forge=forge)
    forge.check_runs[f"{1:040x}"] = ["pending", "success"]
    await handle_incident(make_hook(), d)
    act_lines = [line for line in stage_lines if line.startswith("▸ act:")]
    assert act_lines[0] == "▸ act: pr opened"
    assert "▸ act: merged" in act_lines
    for line in stage_lines:
        assert len(line) <= d.settings.stage_cols
        assert "c" * 7 not in line and "e" * 7 not in line


# -- the clean_status fallback -------------------------------------------------


async def test_clean_status_falls_back_after_check_success(deps) -> None:
    forge = act_forge(auto_merge="clean_status")
    forge.check_runs = {f"{1:040x}": ["missing", "pending", "pending", "success"]}
    d, out = await run(deps, forge=forge)
    assert forge.auto_merges == [(1, "merge")]
    assert [c[1:] for c in calls(forge, "check_run_status")] == [(f"{1:040x}", "policy-check")] * 4
    assert d.sleep.waits == [d.settings.act_check_poll_s] * 3
    assert forge.merged == [(1, "merge", f"{1:040x}")]
    assert out.action == "merged"
    assert d.metrics.value("aiops_actions_total", action="merged") == 1


async def test_clean_status_never_merges_before_check_success(deps) -> None:
    forge = act_forge(auto_merge="clean_status")
    forge.check_runs = {f"{1:040x}": ["pending", "pending", "failure"]}
    _, out = await run(deps, forge=forge)
    assert calls(forge, "merge_pr") == []
    assert forge.merged == []
    assert len(calls(forge, "check_run_status")) == 3
    assert out.action == "policy_failed"


async def test_policy_failure_leaves_pr_open(deps) -> None:
    """The act flow leaves a failing PR for a human; the reconciler posts the comment, so the
    pipeline neither comments nor emits `policy_failed` itself (no double count)."""
    emitter = RecordingEmitter()
    forge = act_forge(auto_merge="clean_status")
    forge.check_runs = {f"{1:040x}": ["failure"]}
    d, out = await run(deps, forge=forge, emitter=emitter)
    assert out.action == "policy_failed"
    assert out.url == forge.opened[0].pr.url
    assert forge.merged == [] and forge.pr_comments == [] and forge.commit_comments == []
    assert "policy_failed" not in actions(emitter)
    assert d.metrics.value("aiops_actions_total", action="policy_failed") == 0


async def test_check_missing_times_out_with_comment(deps) -> None:
    forge = act_forge(auto_merge="clean_status", check_runs={})  # never reports
    d, out = await run(deps, forge=forge)
    s = d.settings
    polls = int(s.act_check_timeout_s // s.act_check_poll_s) + 1
    assert len(calls(forge, "check_run_status")) == polls
    assert sum(d.sleep.waits) == pytest.approx(s.act_check_timeout_s)
    assert forge.merged == []
    [(number, body)] = forge.pr_comments
    assert number == 1
    assert sections()["policy"]["no_result"].format(minutes=10) in body
    assert out.action == "policy_failed"
    assert d.metrics.value("aiops_actions_total", action="policy_failed") == 1


async def test_check_still_pending_at_timeout_is_not_merged(deps) -> None:
    forge = act_forge(auto_merge="clean_status", check_runs={f"{1:040x}": ["pending"]})
    _, out = await run(deps, forge=forge)
    assert forge.merged == []
    assert len(forge.pr_comments) == 1
    assert out.action == "policy_failed"


async def test_check_lookup_error_is_waited_out_never_merged(deps) -> None:
    """A failed check lookup is not a pass: keep polling, and merge only on a real success."""
    forge = act_forge(auto_merge="clean_status")
    forge.check_runs = {f"{1:040x}": [ForgeError("boom", 502), "success"]}
    _, out = await run(deps, forge=forge)
    assert out.action == "merged"
    assert len(calls(forge, "check_run_status")) == 2


async def test_merge_method_from_repo_settings(deps) -> None:
    forge = act_forge(merge_methods_allowed=("squash", "rebase"))
    await run(deps, forge=forge)
    assert forge.auto_merges == [(1, "squash")]

    forge = act_forge(merge_methods_allowed=("rebase", "squash", "merge"), auto_merge="clean_status")
    forge.check_runs = {f"{1:040x}": ["success"]}
    await run(deps, forge=forge)
    assert forge.auto_merges == [(1, "merge")]
    assert forge.merged == [(1, "merge", f"{1:040x}")]


async def test_merge_method_lookup_failure_defaults_to_merge(deps) -> None:
    class NoRepoRead(FakeForge):
        async def merge_methods(self) -> tuple[str, ...]:
            raise ForgeError("GET : 502", 502)

    base = act_forge()
    forge = NoRepoRead(**{k: getattr(base, k) for k in ("files", "commits", "titles")})
    await run(deps, forge=forge)
    assert forge.auto_merges == [(1, "merge")]


async def test_act_pr_footer_states_act_level(deps) -> None:
    d, _ = await run(deps)
    [opened] = d.forge.opened
    assert opened.body.rstrip().splitlines()[-1] == sections()["footer"]["act"]


async def test_act_emits_auto_merge_and_merged_events(deps) -> None:
    # Enabled path: pr_opened, then auto_merge_enabled; GitHub's merge is the reconciler's to report.
    emitter = RecordingEmitter()
    await run(deps, emitter=emitter)
    assert actions(emitter) == ["pr_opened", "auto_merge_enabled"]
    assert events.CHANGE_MERGED not in emitter.types()
    assert "dev.cdevents.change.created.0.4.0" in emitter.types()

    # Fallback path: the bridge's own merge emits change.merged with the merge SHA.
    emitter = RecordingEmitter()
    forge = act_forge(auto_merge="clean_status", check_runs={f"{1:040x}": ["success"]})
    d, out = await run(deps, forge=forge, emitter=emitter)
    assert actions(emitter) == ["pr_opened", "merged"]
    [merged] = [e for e in emitter.events if e["context"]["type"] == events.CHANGE_MERGED]
    assert merged["customData"]["sha"] == forge.merge_shas[0]
    assert merged["customData"]["merged_by"] == d.settings.bot_login
    assert merged["customData"]["app"] == "checkout"
    assert merged["subject"]["id"] == out.url


async def test_fallback_merge_is_not_announced_again_by_the_reconciler(deps) -> None:
    """The bridge's own merge emits change.merged once; the reconciler, sharing the registry,
    counts the merge but does not emit a second change.merged for it."""
    registry = IncidentRegistry()
    emitter = RecordingEmitter()
    forge = act_forge(auto_merge="clean_status", check_runs={f"{1:040x}": ["success"]})
    d = deps(forge=forge, emitter=emitter, registry=registry)
    rec = Reconciler(forge, d.metrics, emitter, app="checkout", source="s", registry=registry)
    await rec.run_once()  # baseline before the incident
    await handle_incident(make_hook(), d)
    forge.agent_prs = [forge.info(1, state="closed", merged=True, merged_by=d.settings.bot_login)]
    await rec.run_once()
    await rec.run_once()
    assert emitter.types().count(events.CHANGE_MERGED) == 1
    assert d.metrics.value("aiops_fix_prs_total", outcome="merged") == 1


async def test_auto_merge_error_is_post_failed_and_never_merges(deps) -> None:
    forge = act_forge(auto_merge=ForgeError("graphql: FORBIDDEN", 200))
    d, out = await run(deps, forge=forge)
    assert out.post_failed is True
    assert out.action == "auto_merge_enabled"
    assert forge.merged == [] and calls(forge, "check_run_status") == []
    assert d.metrics.value("aiops_actions_total", action="post_failed") == 1


async def test_fallback_merge_refused_is_post_failed(deps) -> None:
    forge = act_forge(auto_merge="clean_status", check_runs={f"{1:040x}": ["success"]},
                      fail_merge=ForgeError("PUT /pulls/1/merge: 405", 405))
    registry = IncidentRegistry()
    _, out = await run(deps, forge=forge, registry=registry)
    assert out.action == "merged" and out.post_failed is True
    assert not registry.merge_announced(1)  # the reconciler may still report a later merge


async def test_act_refusal_posts_comment_not_pr(deps) -> None:
    forge = act_forge()
    d = deps(forge=forge)
    d.holmes = StubHolmes(rca(confidence=0.1))
    out = await handle_incident(make_hook(), d)
    assert out.action == "refused"
    assert forge.opened == [] and forge.auto_merges == []
    [(_, body)] = forge.commit_comments
    assert sections()["refusal"]["act"] in body


async def test_act_open_pr_guard_blocks_second_pr(deps) -> None:
    forge = act_forge()
    d = deps(forge=forge)
    await handle_incident(make_hook(), d)
    d.registry = IncidentRegistry()
    out = await handle_incident(make_hook(), d)
    assert out.action == "duplicate"
    assert len(forge.opened) == 1 and len(forge.auto_merges) == 1


# -- auto-merge lag: the bridge merges if GitHub hasn't, after the check passed --------------


async def test_enabled_path_merges_when_auto_merge_lags(deps) -> None:
    forge = act_forge()
    forge.check_runs = {f"{1:040x}": ["pending", "success"]}
    d, out = await run(deps, forge=forge)
    assert forge.auto_merges == [(1, "merge")]
    assert d.sleep.waits == [d.settings.act_check_poll_s, d.settings.act_automerge_grace_s]
    assert forge.merged == [(1, "merge", f"{1:040x}")]
    assert out.action == "merged"
    assert d.metrics.value("aiops_actions_total", action="auto_merge_enabled") == 1
    assert d.metrics.value("aiops_actions_total", action="merged") == 1


async def test_enabled_path_leaves_merge_to_github_when_it_merged(deps) -> None:
    forge = act_forge(merged_prs={1})
    forge.check_runs = {f"{1:040x}": ["success"]}
    d, out = await run(deps, forge=forge)
    assert calls(forge, "merge_pr") == []
    assert out.action == "auto_merge_enabled"
    assert d.metrics.value("aiops_actions_total", action="merged") == 0


async def test_enabled_path_never_merges_on_check_failure(deps) -> None:
    forge = act_forge()
    forge.check_runs = {f"{1:040x}": ["failure"]}
    _, out = await run(deps, forge=forge)
    assert calls(forge, "merge_pr") == []
    assert out.action == "auto_merge_enabled"


async def test_enabled_path_merge_race_with_github_is_not_a_failure(deps) -> None:
    """GitHub merged between our read and our merge: the 405 is not a post failure."""
    forge = act_forge(fail_merge=ForgeError("PUT /pulls/1/merge: 405", 405), merged_after_merge_call=True)
    forge.check_runs = {f"{1:040x}": ["success"]}
    d, out = await run(deps, forge=forge)
    assert out.action == "auto_merge_enabled"
    assert not out.post_failed
    assert d.metrics.value("aiops_actions_total", action="post_failed") == 0
    assert d.registry.merge_announced(1) is False


async def test_enabled_path_grace_zero_turns_the_catch_up_off(deps) -> None:
    forge = act_forge()
    forge.check_runs = {f"{1:040x}": ["success"]}
    d = deps(forge=forge)
    d.settings.act_automerge_grace_s = 0
    out = await handle_incident(make_hook(), d)
    assert calls(forge, "check_run_status") == []
    assert out.action == "auto_merge_enabled"
