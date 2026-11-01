"""e2e harness: `try-direct-push` proves the App cannot move or delete a protected branch or touch promote/*."""

from __future__ import annotations

import httpx
import pytest
import respx

from bridge.cli import AttemptResult, run_try_direct_push

API = "https://api.github.test"
REPO = "example-org/example-repo"
R = f"{API}/repos/{REPO}"
VIOLATION = {"message": "Repository rule violations found\n\nChanges must be made through a pull request."}


class Tokens:
    async def token(self) -> str:
        return "installation-token-not-a-secret"


def _mock_reads(router: respx.MockRouter, branches: list[str]) -> None:
    for i, b in enumerate(branches):
        sha = f"{i + 1}" * 40
        router.get(f"{R}/git/ref/heads/{b}").mock(return_value=httpx.Response(200, json={"object": {"sha": sha}}))
        router.get(f"{R}/git/commits/{sha}").mock(return_value=httpx.Response(200, json={"tree": {"sha": "t" * 40}}))
    router.post(f"{R}/git/commits").mock(return_value=httpx.Response(201, json={"sha": "c" * 40}))


async def _run(router, branches=("build/demo", "main"), operator_ref=None) -> list[AttemptResult]:
    async with httpx.AsyncClient() as http:
        return await run_try_direct_push(
            http, Tokens(), repo=REPO, branches=list(branches), operator_ref=operator_ref, api_url=API, stamp="T1"
        )


async def test_all_refused_by_ruleset_passes(_no_unmocked_http) -> None:
    r = _no_unmocked_http
    _mock_reads(r, ["build/demo", "main"])
    r.patch(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.delete(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.post(f"{R}/git/refs").mock(return_value=httpx.Response(422, json=VIOLATION))
    results = await _run(r)
    kinds = [(x.target, x.action) for x in results]
    assert ("build/demo", "move") in kinds and ("build/demo", "delete") in kinds
    assert ("main", "move") in kinds and ("main", "delete") in kinds
    assert ("promote/app-test-T1", "create") in kinds
    assert all(x.ok for x in results)


async def test_unrelated_4xx_fails(_no_unmocked_http) -> None:
    r = _no_unmocked_http
    _mock_reads(r, ["main"])
    r.patch(url__regex=rf"{R}/git/refs/heads/.*").mock(
        return_value=httpx.Response(403, json={"message": "Resource not accessible by integration"})
    )
    r.delete(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.post(f"{R}/git/refs").mock(return_value=httpx.Response(422, json=VIOLATION))
    results = await _run(r, branches=["main"])
    bad = [x for x in results if not x.ok]
    assert [(x.target, x.action) for x in bad] == [("main", "move")]


async def test_success_fails_and_is_undone(_no_unmocked_http) -> None:
    r = _no_unmocked_http
    _mock_reads(r, ["main"])
    moves = r.patch(url__regex=rf"{R}/git/refs/heads/main").mock(return_value=httpx.Response(200, json={}))
    dele = r.delete(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(204))
    restore = r.post(f"{R}/git/refs").mock(return_value=httpx.Response(201, json={}))
    results = await _run(r, branches=["main"])
    assert not all(x.ok for x in results)
    assert moves.call_count == 2          # the attempt, then the force restore to the old head
    assert dele.called
    assert restore.call_count == 2        # re-create of main, and the promote/* create attempt (undone by a delete)
    assert any("restored" in x.detail for x in results)


async def test_operator_ref_move_is_tried(_no_unmocked_http) -> None:
    r = _no_unmocked_http
    _mock_reads(r, ["main"])
    r.get(f"{R}/git/ref/heads/promote/op-test-T1").mock(
        return_value=httpx.Response(200, json={"object": {"sha": "9" * 40}})
    )
    r.get(f"{R}/git/commits/{'9' * 40}").mock(return_value=httpx.Response(200, json={"tree": {"sha": "t" * 40}}))
    r.patch(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.delete(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.post(f"{R}/git/refs").mock(return_value=httpx.Response(422, json=VIOLATION))
    results = await _run(r, branches=["main"], operator_ref="promote/op-test-T1")
    assert ("promote/op-test-T1", "move") in [(x.target, x.action) for x in results]
    assert all(x.ok for x in results)


async def test_token_never_in_results(_no_unmocked_http) -> None:
    r = _no_unmocked_http
    _mock_reads(r, ["main"])
    r.patch(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.delete(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.post(f"{R}/git/refs").mock(return_value=httpx.Response(422, json=VIOLATION))
    results = await _run(r, branches=["main"])
    assert "installation-token" not in repr(results)


def test_refuses_to_run_with_non_ruleset_branch_list() -> None:
    from bridge.cli import main

    with pytest.raises(SystemExit):
        main(["try-direct-push", "--repo", "badrepo"])


GENERIC = {"message": "Reference update failed"}


async def test_generic_create_422_passes_only_with_a_working_control(_no_unmocked_http) -> None:
    r = _no_unmocked_http
    _mock_reads(r, ["build/demo"])
    r.patch(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.delete(url__regex=rf"{R}/git/refs/heads/build/demo").mock(return_value=httpx.Response(422, json=VIOLATION))
    cleanup = r.delete(url__regex=rf"{R}/git/refs/heads/rehearse/control-.*").mock(return_value=httpx.Response(204))
    r.post(f"{R}/git/refs").mock(side_effect=[httpx.Response(422, json=GENERIC), httpx.Response(201, json={})])
    results = await _run(r, branches=["build/demo"])
    assert all(x.ok for x in results)
    create = next(x for x in results if x.action == "create")
    assert "control" in create.detail
    assert cleanup.called


async def test_generic_create_422_fails_when_control_also_fails(_no_unmocked_http) -> None:
    r = _no_unmocked_http
    _mock_reads(r, ["build/demo"])
    r.patch(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.delete(url__regex=rf"{R}/git/refs/heads/build/demo").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.post(f"{R}/git/refs").mock(return_value=httpx.Response(422, json=GENERIC))
    results = await _run(r, branches=["build/demo"])
    assert not next(x for x in results if x.action == "create").ok


async def test_default_branch_delete_guard_is_accepted_and_labelled(_no_unmocked_http) -> None:
    r = _no_unmocked_http
    _mock_reads(r, ["main"])
    r.patch(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.delete(url__regex=rf"{R}/git/refs/heads/main").mock(
        return_value=httpx.Response(422, json={"message": "Cannot delete the default branch"})
    )
    r.post(f"{R}/git/refs").mock(return_value=httpx.Response(422, json=VIOLATION))
    results = await _run(r, branches=["main"])
    d = next(x for x in results if x.action == "delete")
    assert d.ok and "default-branch guard" in d.detail


def _mock_operator_ref(r, ref="promote/op-test-T1") -> None:
    r.get(f"{R}/git/ref/heads/{ref}").mock(return_value=httpx.Response(200, json={"object": {"sha": "9" * 40}}))
    r.get(f"{R}/git/commits/{'9' * 40}").mock(return_value=httpx.Response(200, json={"tree": {"sha": "t" * 40}}))


async def test_operator_ref_delete_is_tried_and_refused(_no_unmocked_http) -> None:
    r = _no_unmocked_http
    _mock_reads(r, ["main"])
    _mock_operator_ref(r)
    r.patch(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    dele = r.delete(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.post(f"{R}/git/refs").mock(return_value=httpx.Response(422, json=VIOLATION))
    results = await _run(r, branches=["main"], operator_ref="promote/op-test-T1")
    assert ("promote/op-test-T1", "delete") in [(x.target, x.action) for x in results]
    assert any(c.request.url.path.endswith("/git/refs/heads/promote/op-test-T1") for c in dele.calls)
    assert all(x.ok for x in results)


async def test_operator_ref_delete_that_succeeds_fails_and_recreates_it(_no_unmocked_http) -> None:
    r = _no_unmocked_http
    _mock_reads(r, ["main"])
    _mock_operator_ref(r)
    r.patch(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.delete(url__regex=rf"{R}/git/refs/heads/main").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.delete(url__regex=rf"{R}/git/refs/heads/promote/op-test-T1").mock(return_value=httpx.Response(204))
    posts = r.post(f"{R}/git/refs").mock(
        side_effect=[httpx.Response(422, json=VIOLATION), httpx.Response(201, json={})]
    )
    results = await _run(r, branches=["main"], operator_ref="promote/op-test-T1")
    d = next(x for x in results if x.target == "promote/op-test-T1" and x.action == "delete")
    assert not d.ok and "restored=True" in d.detail
    import json as _json

    assert _json.loads(posts.calls.last.request.content) == {"ref": "refs/heads/promote/op-test-T1", "sha": "9" * 40}


async def test_failed_restore_of_a_protected_branch_names_the_operator_recovery(_no_unmocked_http) -> None:
    r = _no_unmocked_http
    _mock_reads(r, ["main"])
    # the move succeeds (the failure this check exists to catch); the force restore is refused
    r.patch(url__regex=rf"{R}/git/refs/heads/main").mock(
        side_effect=[httpx.Response(200, json={}), httpx.Response(422, json=VIOLATION)]
    )
    r.delete(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.post(f"{R}/git/refs").mock(return_value=httpx.Response(422, json=VIOLATION))
    results = await _run(r, branches=["main"])
    m = next(x for x in results if x.action == "move")
    assert not m.ok and "restored=False" in m.detail
    assert "empty-tree probe commit" in m.detail and "integrity" in m.detail


def test_summary_counts_the_default_branch_guard_separately() -> None:
    from bridge.cli import summarize

    rs = [
        AttemptResult("build/demo", "move", 422, True, "refused: x", "ruleset"),
        AttemptResult("main", "delete", 422, True, "refused by the default-branch guard", "default-branch guard"),
        AttemptResult("promote/x", "create", 422, True, "refused", "ruleset"),
    ]
    assert summarize(rs) == "3/3 attempts refused: 2 by a ruleset, 1 by the default-branch guard"
    rs.append(AttemptResult("main", "move", 200, False, "SUCCEEDED"))
    assert summarize(rs) == "3/4 attempts refused: 2 by a ruleset, 1 by the default-branch guard; 1 FAILED"


async def test_refusals_record_who_refused(_no_unmocked_http) -> None:
    r = _no_unmocked_http
    _mock_reads(r, ["main"])
    r.patch(url__regex=rf"{R}/git/refs/heads/.*").mock(return_value=httpx.Response(422, json=VIOLATION))
    r.delete(url__regex=rf"{R}/git/refs/heads/main").mock(
        return_value=httpx.Response(422, json={"message": "Cannot delete the default branch"})
    )
    r.post(f"{R}/git/refs").mock(return_value=httpx.Response(422, json=VIOLATION))
    results = await _run(r, branches=["main"])
    assert {(x.action, x.refused_by) for x in results} == {
        ("move", "ruleset"), ("delete", "default-branch guard"), ("create", "ruleset")
    }
