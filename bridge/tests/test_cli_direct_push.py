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
