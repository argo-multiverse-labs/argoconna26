"""Task 4.3a: the fix-PR outcome reconciler (polling, gauge-style sets)."""

from __future__ import annotations

import httpx
import pytest
import respx

from bridge import events
from bridge.forge import ForgeError
from bridge.forge.base import PullRequestInfo
from bridge.forge.fake import FakeForge
from bridge.forge.github import GitHubForge
from bridge.metrics import Metrics
from bridge.reconcile import Reconciler

SOURCE = "bridge.test"
APP = "checkout"


class RecordingEmitter:
    def __init__(self) -> None:
        self.events: list[dict] = []

    async def emit(self, event: dict) -> None:
        self.events.append(event)

    def types(self) -> list[str]:
        return [e["context"]["type"] for e in self.events]


def pr(n: int, state: str = "open", *, merged: bool = False, labels: tuple[str, ...] = (), branch: str | None = None):
    return PullRequestInfo(
        number=n,
        url=f"https://forge.test/pull/{n}",
        node_id=f"PR_{n}",
        head_sha=f"{n:040x}",
        branch=branch or f"agent/{APP}-{n:07x}",
        state=state,
        merged=merged,
        merged_by="luke" if merged else None,
        merge_sha=f"{n + 1000:040x}" if merged else None,
        closed_at="2026-11-01T10:00:00Z" if state == "closed" else None,
        labels=labels,
    )


def make(prs: list[PullRequestInfo]):
    forge = FakeForge(agent_prs=prs)
    metrics = Metrics()
    emitter = RecordingEmitter()
    rec = Reconciler(forge, metrics, emitter, app=APP, source=SOURCE, repo="example-org/example-repo")
    return forge, metrics, emitter, rec


def counts(metrics: Metrics) -> tuple[float | None, float | None]:
    return (
        metrics.value("aiops_fix_prs_total", outcome="merged"),
        metrics.value("aiops_fix_prs_total", outcome="rejected"),
    )


async def test_merged_pr_counts_merged() -> None:
    _, metrics, _, rec = make([pr(1, "closed", merged=True), pr(2)])
    await rec.run_once()
    assert counts(metrics) == (1, 0)


async def test_closed_unmerged_counts_rejected() -> None:
    _, metrics, _, rec = make([pr(1, "closed"), pr(2, "closed", merged=True)])
    await rec.run_once()
    assert counts(metrics) == (1, 1)


async def test_reset_and_test_labels_excluded() -> None:
    prs = [
        pr(1, "closed", labels=("demo-reset",)),
        pr(2, "closed", labels=("policy-negative-test", "other")),
        pr(3, "closed", labels=("other",)),
    ]
    _, metrics, emitter, rec = make(prs)
    await rec.run_once()
    assert counts(metrics) == (0, 1)
    # Make the first pass a baseline-free one: a later pass must not announce the excluded PRs either.
    rec.seen.clear()
    await rec.run_once()
    assert all(e["subject"]["id"] != "https://forge.test/pull/1" for e in emitter.events)


async def test_merged_pr_with_demo_reset_not_counted() -> None:
    """O23: an e2e or rehearsal merge never counts on panel 4."""
    _, metrics, _, rec = make([pr(1, "closed", merged=True, labels=("demo-reset",)), pr(2, "closed", merged=True)])
    await rec.run_once()
    assert counts(metrics) == (1, 0)


async def test_merged_pr_with_policy_negative_test_not_counted() -> None:
    _, metrics, _, rec = make([pr(1, "closed", merged=True, labels=("other", "policy-negative-test"))])
    await rec.run_once()
    assert counts(metrics) == (0, 0)


async def test_merged_pr_labelled_later_drops_out_of_the_gauge() -> None:
    """The e2e scripts label the PR after its merge assertions; the next pass must drop it."""
    forge, metrics, _, rec = make([pr(1, "closed", merged=True), pr(2, "closed", merged=True)])
    await rec.run_once()
    assert counts(metrics) == (2, 0)
    forge.agent_prs[1] = pr(2, "closed", merged=True, labels=("demo-reset",))
    await rec.run_once()
    assert counts(metrics) == (1, 0)


async def test_rejected_pr_labelled_later_drops_out_of_the_gauge() -> None:
    forge, metrics, _, rec = make([pr(1, "closed")])
    await rec.run_once()
    assert counts(metrics) == (0, 1)
    forge.agent_prs[0] = pr(1, "closed", labels=("demo-reset",))
    await rec.run_once()
    assert counts(metrics) == (0, 0)


async def test_change_merged_emitted_once_whether_or_not_labelled() -> None:
    """A merge is a real change on the tracked branch, so the timeline gets change.merged either
    way: the label only keeps it off panel 4's count. Labelling after the merge (the usual order)
    must not emit it a second time, and a PR already labelled when first seen still emits once."""
    forge, metrics, emitter, rec = make([pr(1), pr(2)])
    await rec.run_once()  # baseline
    forge.agent_prs[0] = pr(1, "closed", merged=True)
    await rec.run_once()
    assert emitter.types() == [events.CHANGE_MERGED]
    assert counts(metrics) == (1, 0)
    forge.agent_prs[0] = pr(1, "closed", merged=True, labels=("demo-reset",))
    forge.agent_prs[1] = pr(2, "closed", merged=True, labels=("demo-reset",))  # labelled before we looked
    await rec.run_once()
    await rec.run_once()
    assert counts(metrics) == (0, 0)
    assert emitter.types() == [events.CHANGE_MERGED, events.CHANGE_MERGED]
    assert [e["subject"]["id"] for e in emitter.events] == ["https://forge.test/pull/1", "https://forge.test/pull/2"]


async def test_restart_does_not_double_count() -> None:
    forge, metrics, _, rec = make([pr(1, "closed", merged=True), pr(2, "closed")])
    await rec.run_once()
    await rec.run_once()
    assert counts(metrics) == (1, 1)
    # A new process (fresh Reconciler and Metrics) over the same listing lands on the same values.
    metrics2 = Metrics()
    rec2 = Reconciler(forge, metrics2, RecordingEmitter(), app=APP, source=SOURCE)
    await rec2.run_once()
    await rec2.run_once()
    assert counts(metrics2) == (1, 1)


async def test_outcome_event_emitted_once() -> None:
    forge, _, emitter, rec = make([pr(1), pr(2)])
    await rec.run_once()  # baseline: both open
    assert emitter.events == []
    forge.agent_prs[0] = pr(1, "closed", merged=True)
    forge.agent_prs[1] = pr(2, "closed")
    await rec.run_once()
    await rec.run_once()
    await rec.run_once()
    assert sorted(emitter.types()) == sorted([events.CHANGE_MERGED, events.AGENT_ACTION])
    merged = next(e for e in emitter.events if e["context"]["type"] == events.CHANGE_MERGED)
    assert merged["customData"]["merged_by"] == "luke" and merged["customData"]["sha"] == f"{1001:040x}"
    assert merged["customData"]["app"] == "checkout"
    assert merged["context"]["source"] == SOURCE
    rejected = next(e for e in emitter.events if e["context"]["type"] == events.AGENT_ACTION)
    assert rejected["customData"]["action"] == "rejected"
    assert rejected["customData"]["target_url"] == "https://forge.test/pull/2"


async def test_first_pass_is_a_silent_baseline() -> None:
    """History already on the forge when the bridge starts is counted but not announced again."""
    _, metrics, emitter, rec = make([pr(1, "closed", merged=True), pr(2, "closed")])
    await rec.run_once()
    assert counts(metrics) == (1, 1)
    assert emitter.events == []


async def test_excluded_pr_never_emits() -> None:
    forge, _, emitter, rec = make([pr(1)])
    await rec.run_once()
    forge.agent_prs[0] = pr(1, "closed", labels=("demo-reset",))
    await rec.run_once()
    assert emitter.events == []


async def test_forge_error_keeps_last_values() -> None:
    forge, metrics, emitter, rec = make([pr(1, "closed", merged=True)])
    await rec.run_once()
    forge.fail_reads = ForgeError("boom", 502)
    await rec.run_once()  # must not raise, must not reset
    assert counts(metrics) == (1, 0)
    forge.fail_reads = None
    forge.agent_prs.append(pr(2, "closed"))
    await rec.run_once()
    assert counts(metrics) == (1, 1)
    assert emitter.types() == [events.AGENT_ACTION]


async def test_failed_first_pass_does_not_baseline() -> None:
    """A forge error before any successful listing must not mark everything as seen."""
    forge, _, emitter, rec = make([pr(1)])
    forge.fail_reads = ForgeError("boom", 502)
    await rec.run_once()
    forge.fail_reads = None
    await rec.run_once()  # this is the real baseline
    forge.agent_prs[0] = pr(1, "closed")
    await rec.run_once()
    assert emitter.types() == [events.AGENT_ACTION]


async def test_series_start_at_zero_and_other_apps_ignored() -> None:
    _, metrics, _, rec = make([pr(5, "closed", branch="agent/pricing-abc"), pr(6, "closed", branch="feature/x")])
    await rec.run_once()
    assert counts(metrics) == (0, 0)


# --- the GitHub implementation of list_agent_prs ---

API = "https://api.github.test"
REPO = "example-org/example-repo"
BASE = f"{API}/repos/{REPO}"
BOT = "argoconna26-agent[bot]"


class StaticToken:
    async def token(self) -> str:
        return "inst-token"


def gh_pr(n, branch, login=BOT, *, state="open", merged_at=None, labels=()):
    return {
        "number": n,
        "html_url": f"https://github.test/{REPO}/pull/{n}",
        "node_id": f"PR_{n}",
        "state": state,
        "merged_at": merged_at,
        "closed_at": "2026-11-01T10:00:00Z" if state == "closed" else None,
        "merge_commit_sha": f"{n + 1000:040x}" if merged_at else None,
        "head": {"ref": branch, "sha": f"{n:040x}"},
        "user": {"login": login},
        "labels": [{"name": name} for name in labels],
    }


@pytest.fixture
async def forge():
    async with httpx.AsyncClient() as http:
        yield GitHubForge(REPO, StaticToken(), api_url=API, http=http)


@respx.mock(assert_all_mocked=True)
async def test_github_list_agent_prs_states_and_filters(respx_mock, forge: GitHubForge) -> None:
    route = respx_mock.get(f"{BASE}/pulls").mock(
        return_value=httpx.Response(
            200,
            json=[
                gh_pr(1, "agent/checkout-a"),
                gh_pr(2, "agent/checkout-b", state="closed", labels=("demo-reset",)),
                gh_pr(3, "agent/checkout-c", state="closed", merged_at="2026-11-01T10:00:00Z"),
                gh_pr(4, "agent/checkout-d", "someone-else", state="closed"),
                gh_pr(5, "agent/pricing-a", state="closed"),
            ],
        )
    )
    respx_mock.get(f"{BASE}/pulls/3").mock(
        return_value=httpx.Response(200, json={**gh_pr(3, "agent/checkout-c"), "merged_by": {"login": "luke"}})
    )
    prs = await forge.list_agent_prs("checkout", "all")
    assert route.calls[0].request.url.params["state"] == "all"
    assert [p.number for p in prs] == [1, 2, 3]
    by = {p.number: p for p in prs}
    assert by[1].state == "open" and not by[1].merged
    assert by[2].labels == ("demo-reset",) and by[2].state == "closed" and not by[2].merged
    assert by[3].merged and by[3].merged_by == "luke" and by[3].merge_sha == f"{1003:040x}"
    assert by[3].branch == "agent/checkout-c" and by[3].closed_at


@respx.mock(assert_all_mocked=True)
async def test_github_list_agent_prs_open_filter_and_paging(respx_mock, forge: GitHubForge) -> None:
    page1 = [gh_pr(n, "feature/x", "someone") for n in range(1, 101)]
    page2 = [gh_pr(200, "agent/checkout-z")]
    route = respx_mock.get(f"{BASE}/pulls").mock(
        side_effect=lambda req: httpx.Response(200, json=page1 if req.url.params["page"] == "1" else page2)
    )
    prs = await forge.list_agent_prs("checkout", "open")
    assert [p.number for p in prs] == [200]
    assert route.call_count == 2


@respx.mock(assert_all_mocked=True)
async def test_github_list_agent_prs_error_raises(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/pulls").mock(return_value=httpx.Response(502))
    with pytest.raises(ForgeError):
        await forge.list_agent_prs("checkout", "all")


# --- Task 5.4: policy-check results, counted on both act paths ---

POLICY_FAILED = "dev.cdeventsx.agent-action.0.1.0"


def policy_counts(metrics: Metrics) -> tuple[float | None, float | None]:
    return (
        metrics.value("aiops_policy_checks_total", result="pass"),
        metrics.value("aiops_policy_checks_total", result="fail"),
    )


def policy_actions(emitter: RecordingEmitter) -> list[dict]:
    return [
        e for e in emitter.events
        if e["context"]["type"] == events.AGENT_ACTION and e["customData"]["action"] == "policy_failed"
    ]


def with_checks(forge: FakeForge, statuses: dict[int, str]) -> None:
    forge.check_runs = {f"{n:040x}": [status] for n, status in statuses.items()}


async def test_policy_series_start_at_zero() -> None:
    _, metrics, _, _ = make([])
    assert policy_counts(metrics) == (0, 0)


async def test_enabled_path_policy_pass_counted() -> None:
    """Auto-merge was enabled while the check was pending; GitHub merged after it passed. The
    act flow never looked again, so the count comes from the reconciler."""
    forge, metrics, _, rec = make([pr(1, "closed", merged=True), pr(2), pr(3)])
    with_checks(forge, {1: "success", 2: "pending", 3: "missing"})
    await rec.run_once()
    assert policy_counts(metrics) == (1, 0)
    assert next(c[1:] for c in forge.calls if c[0] == "check_run_status") == (f"{1:040x}", "policy-check")


async def test_enabled_path_policy_fail_comments_once() -> None:
    forge, metrics, emitter, rec = make([pr(1)])
    with_checks(forge, {1: "failure"})
    await rec.run_once()
    await rec.run_once()
    assert policy_counts(metrics) == (0, 1)
    [(number, body)] = forge.pr_comments
    assert number == 1
    assert "Policy check failed; leaving this for a human." in body
    [event] = policy_actions(emitter)
    assert event["customData"]["target_url"] == "https://forge.test/pull/1"
    assert event["customData"]["app"] == APP
    assert metrics.value("aiops_actions_total", action="policy_failed") == 1


async def test_policy_fail_comment_survives_a_restart() -> None:
    """A new process finds its own marker comment on the PR and posts nothing more."""
    forge, _, _, rec = make([pr(1)])
    with_checks(forge, {1: "failure"})
    await rec.run_once()
    rec2 = Reconciler(forge, Metrics(), (emitter2 := RecordingEmitter()), app=APP, source=SOURCE)
    await rec2.run_once()
    await rec2.run_once()
    assert len(forge.pr_comments) == 1
    assert policy_actions(emitter2) == []


async def test_policy_fail_comment_retried_after_a_failed_post() -> None:
    forge, _, emitter, rec = make([pr(1)])
    with_checks(forge, {1: "failure"})
    forge.fail_writes = ForgeError("POST /issues/1/comments: 502", 502)
    await rec.run_once()
    assert forge.pr_comments == [] and policy_actions(emitter) == []
    forge.fail_writes = None
    await rec.run_once()
    assert len(forge.pr_comments) == 1 and len(policy_actions(emitter)) == 1


async def test_fallback_path_policy_fail_not_double_commented(settings) -> None:
    """clean_status fallback: the act flow sees the failure and leaves the PR; the reconciler
    then comments once. One comment and one policy_failed event in all."""
    from bridge.incidents import IncidentRegistry
    from bridge.pipeline import Deps, handle_incident

    from .test_act import Sleeper, act_forge
    from .test_pipeline_suggest import NOW, StubHolmes, make_hook, rca

    forge = act_forge(auto_merge="clean_status", check_runs={f"{1:040x}": ["pending", "failure"]})
    emitter = RecordingEmitter()
    metrics = Metrics()
    registry = IncidentRegistry()
    deps = Deps(forge=forge, holmes=StubHolmes(rca()), emitter=emitter, settings=settings, registry=registry,
                clock=lambda: NOW, metrics=metrics, sleep=Sleeper())
    rec = Reconciler(forge, metrics, emitter, app=APP, source=SOURCE, registry=registry)
    await rec.run_once()  # baseline: nothing yet
    out = await handle_incident(make_hook(), deps)
    assert out.action == "policy_failed"
    forge.agent_prs = [forge.info(1)]
    await rec.run_once()
    await rec.run_once()
    assert len(forge.pr_comments) == 1
    assert len(policy_actions(emitter)) == 1
    assert policy_counts(metrics) == (0, 1)
    assert metrics.value("aiops_actions_total", action="policy_failed") == 1


async def test_policy_fail_on_closed_pr_counted_not_commented() -> None:
    forge, metrics, emitter, rec = make([pr(1, "closed")])
    with_checks(forge, {1: "failure"})
    await rec.run_once()
    assert policy_counts(metrics) == (0, 1)
    assert forge.pr_comments == [] and policy_actions(emitter) == []


async def test_policy_metric_set_from_listing_not_incremented() -> None:
    forge, metrics, _, rec = make([pr(1, "closed", merged=True), pr(2, "closed", merged=True), pr(3, "closed")])
    with_checks(forge, {1: "success", 2: "success", 3: "failure"})
    for _ in range(3):
        await rec.run_once()
    assert policy_counts(metrics) == (2, 1)
    # A restart (fresh Reconciler and Metrics) over the same listing gives the same values.
    metrics2 = Metrics()
    rec2 = Reconciler(forge, metrics2, RecordingEmitter(), app=APP, source=SOURCE)
    await rec2.run_once()
    await rec2.run_once()
    assert policy_counts(metrics2) == (2, 1)


async def test_policy_negative_and_reset_labels_excluded() -> None:
    """O23: harness PRs count on neither panel-4 series, get no comment and cost no check read."""
    prs = [
        pr(1, labels=("policy-negative-test",)),
        pr(2, "closed", merged=True, labels=("demo-reset",)),
        pr(3, "closed", merged=True),
    ]
    forge, metrics, emitter, rec = make(prs)
    with_checks(forge, {1: "failure", 2: "success", 3: "success"})
    await rec.run_once()
    await rec.run_once()
    assert policy_counts(metrics) == (1, 0)
    assert forge.pr_comments == [] and policy_actions(emitter) == []
    checked = {c[1] for c in forge.calls if c[0] == "check_run_status"}
    assert checked == {f"{3:040x}"}


async def test_policy_labelled_later_drops_out_of_the_count() -> None:
    forge, metrics, _, rec = make([pr(1, "closed", merged=True)])
    with_checks(forge, {1: "success"})
    await rec.run_once()
    assert policy_counts(metrics) == (1, 0)
    forge.agent_prs[0] = pr(1, "closed", merged=True, labels=("demo-reset",))
    await rec.run_once()
    assert policy_counts(metrics) == (0, 0)


async def test_policy_check_error_keeps_last_policy_values() -> None:
    forge, metrics, _, rec = make([pr(1, "closed", merged=True), pr(2)])
    forge.check_runs = {f"{1:040x}": ["success"], f"{2:040x}": [ForgeError("boom", 502)]}
    await rec.run_once()
    assert policy_counts(metrics) == (0, 0)  # never set from a partial read
    assert counts(metrics) == (1, 0)  # the outcome counts don't depend on the checks
    forge.check_runs[f"{2:040x}"] = ["failure"]
    await rec.run_once()
    assert policy_counts(metrics) == (1, 1)


async def test_concluded_check_on_closed_pr_read_once() -> None:
    forge, _, _, rec = make([pr(1, "closed", merged=True), pr(2)])
    with_checks(forge, {1: "success", 2: "pending"})
    for _ in range(3):
        await rec.run_once()
    reads = [c[1] for c in forge.calls if c[0] == "check_run_status"]
    assert reads.count(f"{1:040x}") == 1
    assert reads.count(f"{2:040x}") == 3


async def test_reconciler_skips_change_merged_the_pipeline_announced() -> None:
    from bridge.incidents import IncidentRegistry

    registry = IncidentRegistry()
    forge = FakeForge(agent_prs=[pr(1)])
    emitter = RecordingEmitter()
    rec = Reconciler(forge, Metrics(), emitter, app=APP, source=SOURCE, registry=registry)
    await rec.run_once()
    registry.announce_merge(1)
    forge.agent_prs[0] = pr(1, "closed", merged=True)
    await rec.run_once()
    assert events.CHANGE_MERGED not in emitter.types()


# --- the GitHub implementation of the act calls ---


@respx.mock(assert_all_mocked=True)
async def test_github_enable_auto_merge_enabled(respx_mock, forge: GitHubForge) -> None:
    route = respx_mock.post(f"{API}/graphql").mock(
        return_value=httpx.Response(200, json={"data": {"enablePullRequestAutoMerge": {"pullRequest": {}}}})
    )
    from bridge.forge.base import PullRequest

    got = await forge.enable_auto_merge(PullRequest(7, "u", "PR_7", "a" * 40, "agent/checkout-x"), "squash")
    assert got == "enabled"
    sent = route.calls[0].request
    assert sent.headers["Authorization"] == "Bearer inst-token"
    import json as _json

    body = _json.loads(sent.content)
    assert "enablePullRequestAutoMerge" in body["query"]
    assert body["variables"] == {"id": "PR_7", "method": "SQUASH"}


@pytest.mark.parametrize(
    "message", ["Pull request Pull request is in clean status", "Pull request Pull request is in unstable status"]
)
@respx.mock(assert_all_mocked=True)
async def test_github_enable_auto_merge_clean_status(respx_mock, forge: GitHubForge, message: str) -> None:
    respx_mock.post(f"{API}/graphql").mock(
        return_value=httpx.Response(200, json={"data": None, "errors": [{"type": "UNPROCESSABLE", "message": message}]})
    )
    from bridge.forge.base import PullRequest

    assert await forge.enable_auto_merge(PullRequest(7, "u", "PR_7", "a" * 40), "merge") == "clean_status"


@respx.mock(assert_all_mocked=True)
async def test_github_enable_auto_merge_other_error_raises(respx_mock, forge: GitHubForge) -> None:
    respx_mock.post(f"{API}/graphql").mock(
        return_value=httpx.Response(200, json={"errors": [{"type": "FORBIDDEN", "message": "Resource not accessible"}]})
    )
    from bridge.forge.base import PullRequest

    with pytest.raises(ForgeError):
        await forge.enable_auto_merge(PullRequest(7, "u", "PR_7", "a" * 40), "merge")
    respx_mock.post(f"{API}/graphql").mock(return_value=httpx.Response(502))
    with pytest.raises(ForgeError):
        await forge.enable_auto_merge(PullRequest(7, "u", "PR_7", "a" * 40), "merge")


def check_run(run_id: int, status: str, conclusion: str | None, app_id: int = 15368) -> dict:
    return {"id": run_id, "name": "policy-check", "status": status, "conclusion": conclusion, "app": {"id": app_id}}


@pytest.mark.parametrize(
    ("runs", "want"),
    [
        ([], "missing"),
        ([check_run(1, "queued", None)], "pending"),
        ([check_run(1, "in_progress", None)], "pending"),
        ([check_run(1, "completed", "success")], "success"),
        ([check_run(1, "completed", "failure")], "failure"),
        ([check_run(1, "completed", "cancelled")], "failure"),
        ([check_run(1, "completed", "skipped")], "failure"),
        ([check_run(1, "completed", "neutral")], "failure"),
        # The newest run wins (a re-run after a failure).
        ([check_run(1, "completed", "failure"), check_run(2, "completed", "success")], "success"),
        ([check_run(2, "completed", "success"), check_run(3, "in_progress", None)], "pending"),
        # A same-named check from another app never counts (the ruleset pins GitHub Actions).
        ([check_run(1, "completed", "success", app_id=999)], "missing"),
    ],
)
@respx.mock(assert_all_mocked=True)
async def test_github_check_run_status(respx_mock, forge: GitHubForge, runs: list[dict], want: str) -> None:
    sha = "b" * 40
    route = respx_mock.get(f"{BASE}/commits/{sha}/check-runs").mock(
        return_value=httpx.Response(200, json={"total_count": len(runs), "check_runs": runs})
    )
    assert await forge.check_run_status(sha) == want
    assert route.calls[0].request.url.params["check_name"] == "policy-check"


@respx.mock(assert_all_mocked=True)
async def test_github_check_run_status_error_raises(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/commits/{'b' * 40}/check-runs").mock(return_value=httpx.Response(502))
    with pytest.raises(ForgeError):
        await forge.check_run_status("b" * 40)


@respx.mock(assert_all_mocked=True)
async def test_github_merge_pr_pins_the_head_sha(respx_mock, forge: GitHubForge) -> None:
    from bridge.forge.base import PullRequest

    route = respx_mock.put(f"{BASE}/pulls/7/merge").mock(
        return_value=httpx.Response(200, json={"sha": "d" * 40, "merged": True})
    )
    sha = await forge.merge_pr(PullRequest(7, "u", "PR_7", "a" * 40), "merge")
    assert sha == "d" * 40
    import json as _json

    assert _json.loads(route.calls[0].request.content) == {"merge_method": "merge", "sha": "a" * 40}
    respx_mock.put(f"{BASE}/pulls/7/merge").mock(return_value=httpx.Response(409))
    with pytest.raises(ForgeError):
        await forge.merge_pr(PullRequest(7, "u", "PR_7", "a" * 40), "merge")


@respx.mock(assert_all_mocked=True)
async def test_github_merge_methods(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(BASE).mock(
        return_value=httpx.Response(
            200, json={"allow_merge_commit": False, "allow_squash_merge": True, "allow_rebase_merge": True}
        )
    )
    assert await forge.merge_methods() == ("squash", "rebase")


@respx.mock(assert_all_mocked=True)
async def test_github_list_pr_comments_only_the_bots(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/issues/7/comments").mock(
        return_value=httpx.Response(
            200,
            json=[
                {"user": {"login": BOT}, "body": "mine"},
                {"user": {"login": "someone"}, "body": "theirs <!-- aiops:policy-failed -->"},
            ],
        )
    )
    assert await forge.list_pr_comments(7) == ["mine"]


async def test_change_merged_survives_a_pass_between_announce_and_a_failed_merge() -> None:
    """catch_up announces, then its merge_pr loses the race to GitHub's auto-merge. A reconciler
    pass that runs while that request is in flight sees the PR merged and skips it (announced);
    forget_merge then hands it back, and the next pass must emit change.merged, once."""
    from bridge.incidents import IncidentRegistry

    registry = IncidentRegistry()
    forge = FakeForge(agent_prs=[pr(1)])
    emitter = RecordingEmitter()
    rec = Reconciler(forge, Metrics(), emitter, app=APP, source=SOURCE, registry=registry)
    await rec.run_once()  # baseline: open
    registry.announce_merge(1)  # catch_up, before merge_pr
    forge.agent_prs[0] = pr(1, "closed", merged=True)  # GitHub's auto-merge lands first
    await rec.run_once()  # the interleaved pass: skipped as announced
    assert events.CHANGE_MERGED not in emitter.types()
    registry.forget_merge(1)  # merge_pr failed (405)
    await rec.run_once()
    assert emitter.types().count(events.CHANGE_MERGED) == 1
    await rec.run_once()
    assert emitter.types().count(events.CHANGE_MERGED) == 1


async def test_forgotten_merge_of_an_open_pr_is_reported_once_when_a_person_merges_it() -> None:
    from bridge.incidents import IncidentRegistry

    registry = IncidentRegistry()
    forge = FakeForge(agent_prs=[pr(1)])
    emitter = RecordingEmitter()
    rec = Reconciler(forge, Metrics(), emitter, app=APP, source=SOURCE, registry=registry)
    await rec.run_once()
    registry.announce_merge(1)
    registry.forget_merge(1)  # the merge failed and the PR stayed open
    await rec.run_once()
    assert events.CHANGE_MERGED not in emitter.types()
    forge.agent_prs[0] = pr(1, "closed", merged=True)
    await rec.run_once()
    await rec.run_once()
    assert emitter.types().count(events.CHANGE_MERGED) == 1


async def test_a_successful_announced_merge_is_never_reported_by_the_reconciler() -> None:
    from bridge.incidents import IncidentRegistry

    registry = IncidentRegistry()
    forge = FakeForge(agent_prs=[pr(1)])
    emitter = RecordingEmitter()
    rec = Reconciler(forge, Metrics(), emitter, app=APP, source=SOURCE, registry=registry)
    await rec.run_once()
    registry.announce_merge(1)
    forge.agent_prs[0] = pr(1, "closed", merged=True)
    for _ in range(3):
        await rec.run_once()
    assert events.CHANGE_MERGED not in emitter.types()
