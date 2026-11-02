"""e2e harness: `spike-pr` opens an App-authored two-line PR on the scratch branch and enables auto-merge."""

from __future__ import annotations

import base64
import json

import httpx
import pytest

from bridge.cli import SPIKE_BASE, SpikeError, run_spike_pr

API = "https://api.github.test"
REPO = "example-org/example-repo"
R = f"{API}/repos/{REPO}"
README = "# pricing\n\nThe pricing service answers GET /price for checkout.\n\nNotes revision: 18\n"


class Tokens:
    async def token(self) -> str:
        return "installation-token-not-a-secret"


async def _no_sleep(_: float) -> None:
    return None


def _mock_happy(r, *, states=("OPEN", "MERGED"), graphql=None):
    r.get(f"{R}/git/ref/heads/{SPIKE_BASE}").mock(return_value=httpx.Response(200, json={"object": {"sha": "a" * 40}}))
    r.get(f"{R}/contents/apps/pricing/README.md").mock(
        return_value=httpx.Response(200, json={"sha": "b" * 40, "content": base64.b64encode(README.encode()).decode()})
    )
    refs = r.post(f"{R}/git/refs").mock(return_value=httpx.Response(201, json={}))
    put = r.put(f"{R}/contents/apps/pricing/README.md").mock(return_value=httpx.Response(200, json={"commit": {"sha": "d" * 40}}))
    pr = r.post(f"{R}/pulls").mock(return_value=httpx.Response(201, json={"number": 7, "node_id": "PR_node", "html_url": "u"}))
    gql = r.post(f"{API}/graphql").mock(
        return_value=httpx.Response(200, json=graphql or {"data": {"enablePullRequestAutoMerge": {"pullRequest": {"autoMergeRequest": {"enabledAt": "t"}}}}})
    )
    seq = iter(states)
    def view(_req):
        s = next(seq, states[-1])
        return httpx.Response(200, json={"number": 7, "state": "CLOSED" if s == "MERGED" else s, "merged": s == "MERGED",
                                         "mergeable_state": "blocked" if s == "OPEN" else "clean"})
    r.get(f"{R}/pulls/7").mock(side_effect=view)
    r.delete(f"{R}/git/refs/heads/agent/spike-T1").mock(return_value=httpx.Response(204))
    return refs, put, pr, gql


async def _run(**kw):
    async with httpx.AsyncClient() as http:
        return await run_spike_pr(http, Tokens(), repo=REPO, base=kw.pop("base", SPIKE_BASE), api_url=API,
                                  stamp="T1", sleep=_no_sleep, timeout_s=30, poll_s=1, **kw)


async def test_refuses_any_other_base_before_any_http(_no_unmocked_http) -> None:
    for bad in ("build/demo", "main", "rehearse/other", "promote/x"):
        with pytest.raises(SpikeError, match="rehearse/merge-spike"):
            await _run(base=bad)
    assert not _no_unmocked_http.calls


async def test_two_line_pr_changes_exactly_one_line(_no_unmocked_http) -> None:
    refs, put, pr, _ = _mock_happy(_no_unmocked_http)
    res = await _run(scenario="two-line")
    body = json.loads(put.calls.last.request.content)
    new = base64.b64decode(body["content"]).decode()
    assert new == README.replace("Notes revision: 18", "Notes revision: 19")
    assert body["sha"] == "b" * 40 and body["branch"] == "agent/spike-T1"
    assert json.loads(refs.calls.last.request.content) == {"ref": "refs/heads/agent/spike-T1", "sha": "a" * 40}
    assert json.loads(pr.calls.last.request.content)["base"] == SPIKE_BASE
    assert res.number == 7 and res.merged and res.auto_merge_enabled


async def test_auto_merge_goes_through_graphql_with_node_id(_no_unmocked_http) -> None:
    _, _, _, gql = _mock_happy(_no_unmocked_http)
    await _run(scenario="two-line")
    q = json.loads(gql.calls.last.request.content)
    assert "enablePullRequestAutoMerge" in q["query"]
    assert q["variables"]["id"] == "PR_node"


async def test_graphql_error_is_reported_not_swallowed(_no_unmocked_http) -> None:
    _mock_happy(_no_unmocked_http, states=("OPEN",), graphql={"errors": [{"message": "Pull request is not in the right state"}]})
    res = await _run(scenario="two-line", wait=False)
    assert not res.auto_merge_enabled and "not in the right state" in res.auto_merge_error


async def test_timeout_reports_final_state(_no_unmocked_http) -> None:
    _mock_happy(_no_unmocked_http, states=("OPEN",))
    res = await _run(scenario="two-line")
    assert not res.merged and res.final_state == "OPEN" and res.mergeable_state == "blocked"


async def test_token_never_in_result(_no_unmocked_http) -> None:
    _mock_happy(_no_unmocked_http)
    res = await _run(scenario="two-line")
    assert "installation-token" not in repr(res)


async def test_head_branch_deleted_after_merge(_no_unmocked_http) -> None:
    _mock_happy(_no_unmocked_http)
    res = await _run(scenario="two-line")
    dele = [c for c in _no_unmocked_http.calls if c.request.method == "DELETE"]
    assert [c.request.url.path for c in dele] == [f"/repos/{REPO}/git/refs/heads/agent/spike-T1"]
    assert res.merged and res.branch_deleted


async def test_head_branch_deleted_after_close(_no_unmocked_http) -> None:
    _mock_happy(_no_unmocked_http, states=("OPEN", "CLOSED"))
    res = await _run(scenario="two-line")
    assert res.final_state == "CLOSED" and res.branch_deleted


async def test_head_branch_kept_while_pr_still_open(_no_unmocked_http) -> None:
    _mock_happy(_no_unmocked_http, states=("OPEN",))
    res = await _run(scenario="two-line")
    assert not [c for c in _no_unmocked_http.calls if c.request.method == "DELETE"]
    assert res.final_state == "OPEN" and not res.branch_deleted


AUTONOMY = "apiVersion: aiops.example.dev/v1\nkind: Autonomy\nlevel: suggest\npromotion: null\n"


def _mock_raise(r, *, autonomy=AUTONOMY, merge_status=405):
    r.get(f"{R}/git/ref/heads/{SPIKE_BASE}").mock(return_value=httpx.Response(200, json={"object": {"sha": "a" * 40}}))
    r.get(f"{R}/contents/aiops/autonomy.yaml").mock(
        return_value=httpx.Response(200, json={"sha": "c" * 40, "content": base64.b64encode(autonomy.encode()).decode()})
    )
    r.post(f"{R}/git/refs").mock(return_value=httpx.Response(201, json={}))
    put = r.put(f"{R}/contents/aiops/autonomy.yaml").mock(return_value=httpx.Response(200, json={}))
    r.post(f"{R}/pulls").mock(return_value=httpx.Response(201, json={"number": 9, "node_id": "PR_9", "html_url": "u9"}))
    r.post(f"{API}/graphql").mock(return_value=httpx.Response(200, json={"data": {"enablePullRequestAutoMerge": {}}}))
    merge = r.put(f"{R}/pulls/9/merge").mock(return_value=httpx.Response(merge_status, json={"message": "blocked"}))
    view = r.get(f"{R}/pulls/9").mock(return_value=httpx.Response(
        200, json={"number": 9, "state": "open", "merged": False, "mergeable_state": "blocked"}))
    return put, merge, view


async def test_autonomy_raise_sets_act_tries_rest_merge_and_does_not_wait(_no_unmocked_http) -> None:
    put, merge, view = _mock_raise(_no_unmocked_http)
    res = await _run(scenario="autonomy-raise")
    sent = json.loads(put.calls.last.request.content)
    assert "level: act\n" in base64.b64decode(sent["content"]).decode()
    assert sent["branch"] == "agent/spike-T1"
    assert merge.call_count == 1 and res.rest_merge_status == 405
    assert view.call_count == 1  # one read, no waiting for a merge
    assert res.final_state == "OPEN" and not res.merged and not res.branch_deleted


async def test_autonomy_raise_refuses_when_already_act(_no_unmocked_http) -> None:
    _mock_raise(_no_unmocked_http, autonomy=AUTONOMY.replace("level: suggest", "level: act"))
    with pytest.raises(SpikeError, match="already at act"):
        await _run(scenario="autonomy-raise")


async def test_unknown_scenario_refused_before_any_http(_no_unmocked_http) -> None:
    with pytest.raises(SpikeError, match="unknown scenario"):
        await _run(scenario="something-else")
    assert not _no_unmocked_http.calls


async def test_autonomy_raise_records_the_rest_merge_message(_no_unmocked_http) -> None:
    _mock_raise(_no_unmocked_http)
    res = await _run(scenario="autonomy-raise")
    assert res.rest_merge_message == "blocked"


@pytest.mark.parametrize(
    ("status", "message", "refused"),
    [
        (405, "Repository rule violations found\n\nWaiting on code owner review from org/promotion-board.", True),
        (405, "At least 1 approving review is required by reviewers with write access.", True),
        # the required check refuses too, but that proves nothing about code-owner review
        (405, 'Required status check "policy-check" is expected.', False),
        (405, "Base branch was modified. Review and try the merge again.", False),
        (200, "Pull Request successfully merged", False),
        (None, "", False),
    ],
)
def test_autonomy_raise_counts_only_a_code_owner_refusal(status, message, refused) -> None:
    from bridge.cli import SpikeResult, autonomy_raise_refused

    res = SpikeResult(number=9, url="u", branch="b", auto_merge_enabled=True, auto_merge_error="",
                      merged=False, final_state="OPEN", mergeable_state="blocked", waited_s=0,
                      rest_merge_status=status, rest_merge_message=message)
    assert autonomy_raise_refused(res) is refused
