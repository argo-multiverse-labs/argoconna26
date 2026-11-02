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
