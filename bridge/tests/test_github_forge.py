"""Task 3.5: the GitHub forge over REST, stubbed with respx; and DryForge."""

from __future__ import annotations

import base64
import json
import logging

import httpx
import pytest
import respx

from bridge.forge import DryForge, Forge, ForgeConflict, ForgeError, ForgeNotFound
from bridge.forge.fake import FakeForge
from bridge.forge.github import GitHubForge

API = "https://api.github.test"
REPO = "example-org/example-repo"
BASE = f"{API}/repos/{REPO}"
SHA = "0123456789abcdef0123456789abcdef01234567"
OTHER = "fedcba9876543210fedcba9876543210fedcba98"


class StaticToken:
    async def token(self) -> str:
        return "inst-token"


@pytest.fixture
async def forge():
    async with httpx.AsyncClient() as http:
        yield GitHubForge(REPO, StaticToken(), api_url=API, http=http)


def test_implementations_satisfy_protocol(forge) -> None:
    assert isinstance(forge, Forge)
    assert isinstance(FakeForge(), Forge)
    assert isinstance(DryForge(FakeForge()), Forge)


@respx.mock(assert_all_mocked=True)
async def test_read_file_decodes_base64(respx_mock, forge: GitHubForge) -> None:
    content = "level: suggest\n"
    encoded = base64.encodebytes(content.encode()).decode()  # GitHub wraps at 60 chars
    route = respx_mock.get(f"{BASE}/contents/aiops/autonomy.yaml", params={"ref": "build/demo"}).mock(
        return_value=httpx.Response(200, json={"encoding": "base64", "content": encoded})
    )
    assert await forge.read_file("aiops/autonomy.yaml", "build/demo") == content
    headers = route.calls[0].request.headers
    assert headers["Authorization"] == "Bearer inst-token"
    assert headers["Accept"] == "application/vnd.github+json"


@respx.mock(assert_all_mocked=True)
async def test_read_file_404_is_not_found(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/contents/aiops/autonomy.yaml").mock(return_value=httpx.Response(404))
    with pytest.raises(ForgeNotFound):
        await forge.read_file("aiops/autonomy.yaml", "build/demo")


@respx.mock(assert_all_mocked=True)
async def test_server_error_is_forge_error(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/contents/aiops/autonomy.yaml").mock(return_value=httpx.Response(502))
    with pytest.raises(ForgeError):
        await forge.read_file("aiops/autonomy.yaml", "build/demo")


@respx.mock(assert_all_mocked=True)
async def test_network_error_is_forge_error(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/contents/aiops/autonomy.yaml").mock(side_effect=httpx.ConnectError("down"))
    with pytest.raises(ForgeError):
        await forge.read_file("aiops/autonomy.yaml", "build/demo")


@respx.mock(assert_all_mocked=True)
async def test_resolve_short_sha(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/commits/0123456").mock(return_value=httpx.Response(200, json={"sha": SHA}))
    assert await forge.resolve_sha("0123456") == SHA


@respx.mock(assert_all_mocked=True)
async def test_resolve_unknown_sha_is_none(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/commits/abcdef1").mock(return_value=httpx.Response(422))
    assert await forge.resolve_sha("abcdef1") is None


async def test_resolve_rejects_non_hex_without_calling(forge: GitHubForge) -> None:
    with respx.mock(assert_all_mocked=True, assert_all_called=False) as mock:
        assert await forge.resolve_sha("../../etc") is None
        assert await forge.resolve_sha("HEAD") is None
        assert await forge.resolve_sha("abc") is None  # too short to be unambiguous
        assert mock.calls.call_count == 0


@pytest.mark.parametrize(
    ("status", "expected"), [("ahead", True), ("identical", True), ("behind", False), ("diverged", False)]
)
async def test_is_ancestor_uses_compare_api(forge: GitHubForge, status: str, expected: bool) -> None:
    with respx.mock(assert_all_mocked=True) as respx_mock:
        route = respx_mock.get(f"{BASE}/compare/{SHA}...build/demo").mock(
            return_value=httpx.Response(200, json={"status": status})
        )
        assert await forge.is_ancestor(SHA, "build/demo") is expected
        assert route.called


@respx.mock(assert_all_mocked=True)
async def test_is_ancestor_unknown_sha_false(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/compare/{SHA}...build/demo").mock(return_value=httpx.Response(404))
    assert await forge.is_ancestor(SHA, "build/demo") is False


def _commit(files: list[dict]) -> httpx.Response:
    return httpx.Response(200, json={"sha": SHA, "files": files})


PATCH = """@@ -4,5 +4,5 @@ metadata:
   name: checkout-config
 data:
-  UPSTREAM_TIMEOUT_MS: "2000"
+  UPSTREAM_TIMEOUT_MS: "200"
   LOG_LEVEL: info"""


@respx.mock(assert_all_mocked=True)
async def test_commit_changed_key(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/commits/{SHA}").mock(
        return_value=_commit([{"filename": "apps/checkout/config/checkout-config.yaml", "patch": PATCH}])
    )
    path = "apps/checkout/config/checkout-config.yaml"
    assert await forge.commit_changed_key(SHA, path, "UPSTREAM_TIMEOUT_MS") is True
    assert await forge.commit_changed_key(SHA, path, "LOG_LEVEL") is False  # context line only
    assert await forge.commit_changed_key(SHA, "apps/other/config/x.yaml", "UPSTREAM_TIMEOUT_MS") is False


@respx.mock(assert_all_mocked=True)
async def test_commit_changed_key_ignores_key_as_substring(respx_mock, forge: GitHubForge) -> None:
    patch = "@@ -1 +1 @@\n-  OLD_UPSTREAM_TIMEOUT_MS: 1\n+  OLD_UPSTREAM_TIMEOUT_MS: 2"
    respx_mock.get(f"{BASE}/commits/{SHA}").mock(
        return_value=_commit([{"filename": "apps/checkout/config/c.yaml", "patch": patch}])
    )
    assert await forge.commit_changed_key(SHA, "apps/checkout/config/c.yaml", "UPSTREAM_TIMEOUT_MS") is False


@respx.mock(assert_all_mocked=True)
async def test_comment_on_commit_posts_body(respx_mock, forge: GitHubForge) -> None:
    route = respx_mock.post(f"{BASE}/commits/{SHA}/comments").mock(
        return_value=httpx.Response(201, json={"html_url": "https://github.test/c/1"})
    )
    url = await forge.comment_on_commit(SHA, "## Root cause\nx")
    assert url == "https://github.test/c/1"
    assert json.loads(route.calls[0].request.content) == {"body": "## Root cause\nx"}


@respx.mock(assert_all_mocked=True)
async def test_comment_on_pr_posts_body(respx_mock, forge: GitHubForge) -> None:
    route = respx_mock.post(f"{BASE}/issues/7/comments").mock(
        return_value=httpx.Response(201, json={"html_url": "https://github.test/pr/7#c"})
    )
    assert await forge.comment_on_pr(7, "hello") == "https://github.test/pr/7#c"
    assert json.loads(route.calls[0].request.content) == {"body": "hello"}


@respx.mock(assert_all_mocked=True)
async def test_prs_for_commit(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/commits/{SHA}/pulls").mock(
        return_value=httpx.Response(200, json=[{"number": 12}, {"number": 15}])
    )
    assert await forge.prs_for_commit(SHA) == [12, 15]


@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_dry_forge_reads_through_and_never_writes(respx_mock, caplog: pytest.LogCaptureFixture) -> None:
    encoded = base64.b64encode(b"level: suggest\n").decode()
    respx_mock.get(f"{BASE}/contents/aiops/autonomy.yaml").mock(
        return_value=httpx.Response(200, json={"encoding": "base64", "content": encoded})
    )
    respx_mock.get(f"{BASE}/commits/{SHA}/pulls").mock(return_value=httpx.Response(200, json=[]))
    writes = respx_mock.route(method__in=["POST", "PUT", "PATCH", "DELETE"]).mock(
        return_value=httpx.Response(500)
    )
    caplog.set_level(logging.INFO)
    async with httpx.AsyncClient() as http:
        dry = DryForge(GitHubForge(REPO, StaticToken(), api_url=API, http=http))
        assert await dry.read_file("aiops/autonomy.yaml", "build/demo") == "level: suggest\n"
        assert await dry.prs_for_commit(SHA) == []
        url1 = await dry.comment_on_commit(SHA, "body")
        url2 = await dry.comment_on_pr(3, "body")
    assert writes.call_count == 0
    assert url1.startswith("dry-run:") and url2.startswith("dry-run:")
    assert "▸ dry: would comment" in caplog.text


@respx.mock(assert_all_mocked=True)
async def test_commit_title_is_first_message_line(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/commits/{SHA}").mock(
        return_value=httpx.Response(
            200, json={"sha": SHA, "commit": {"message": "PR-242: tune upstream timeout\n\nDemo-Rearm: 3\n"}}
        )
    )
    assert await forge.commit_title(SHA) == "PR-242: tune upstream timeout"


@respx.mock(assert_all_mocked=True)
async def test_commit_title_unknown_is_none(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/commits/{SHA}").mock(return_value=httpx.Response(404))
    assert await forge.commit_title(SHA) is None


async def test_fake_and_dry_forge_commit_title() -> None:
    fake = FakeForge(titles={SHA: "a title"})
    assert await fake.commit_title(SHA) == "a title"
    assert await fake.commit_title(OTHER) is None
    assert await DryForge(fake).commit_title(SHA) == "a title"


# --- Task 4.1: opening PRs ---------------------------------------------------------------------

BASE_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BASE_TREE = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
NEW_TREE = "cccccccccccccccccccccccccccccccccccccccc"
NEW_COMMIT = "dddddddddddddddddddddddddddddddddddddddd"
CONFIG = "apps/checkout/config/checkout-config.yaml"
ROLLOUT = "apps/checkout/deploy/rollout.yaml"
BOT = "argoconna26-agent[bot]"


def _mock_open_flow(respx_mock, *, ref_status: int = 201):
    respx_mock.get(f"{BASE}/git/ref/heads/build/demo").mock(
        return_value=httpx.Response(200, json={"object": {"sha": BASE_SHA}})
    )
    respx_mock.get(f"{BASE}/git/commits/{BASE_SHA}").mock(
        return_value=httpx.Response(200, json={"sha": BASE_SHA, "tree": {"sha": BASE_TREE}})
    )
    blob_n = iter(range(1, 10))
    blobs = respx_mock.post(f"{BASE}/git/blobs").mock(
        side_effect=lambda req: httpx.Response(201, json={"sha": f"{next(blob_n):040x}"})
    )
    trees = respx_mock.post(f"{BASE}/git/trees").mock(return_value=httpx.Response(201, json={"sha": NEW_TREE}))
    commits = respx_mock.post(f"{BASE}/git/commits").mock(
        return_value=httpx.Response(201, json={"sha": NEW_COMMIT})
    )
    refs = respx_mock.post(f"{BASE}/git/refs").mock(
        return_value=httpx.Response(ref_status, json={"ref": "refs/heads/agent/checkout-1"})
    )
    pulls = respx_mock.post(f"{BASE}/pulls").mock(
        return_value=httpx.Response(
            201,
            json={
                "number": 7,
                "html_url": f"https://github.test/{REPO}/pull/7",
                "node_id": "PR_node7",
                "head": {"sha": NEW_COMMIT},
            },
        )
    )
    return blobs, trees, commits, refs, pulls


@respx.mock(assert_all_mocked=True)
async def test_open_pr_single_commit_two_files(respx_mock, forge: GitHubForge) -> None:
    blobs, trees, commits, refs, pulls = _mock_open_flow(respx_mock)
    pr = await forge.open_pr(
        base="build/demo",
        branch="agent/checkout-abc1234",
        title="fix(checkout): restore upstream timeout",
        body="Cause: abc1234",
        changes={CONFIG: 'UPSTREAM_TIMEOUT_MS: "2000"\n', ROLLOUT: 'example.dev/config-version: "8"\n'},
        commit_message="fix(checkout): restore upstream timeout",
    )
    assert commits.call_count == 1
    assert blobs.call_count == 2
    tree_req = json.loads(trees.calls[0].request.content)
    assert tree_req["base_tree"] == BASE_TREE
    assert {e["path"] for e in tree_req["tree"]} == {CONFIG, ROLLOUT}
    assert len(tree_req["tree"]) == 2
    assert all(e["mode"] == "100644" and e["type"] == "blob" for e in tree_req["tree"])
    commit_req = json.loads(commits.calls[0].request.content)
    assert commit_req == {"message": "fix(checkout): restore upstream timeout", "tree": NEW_TREE, "parents": [BASE_SHA]}
    ref_req = json.loads(refs.calls[0].request.content)
    assert ref_req == {"ref": "refs/heads/agent/checkout-abc1234", "sha": NEW_COMMIT}
    pr_req = json.loads(pulls.calls[0].request.content)
    assert pr_req == {
        "title": "fix(checkout): restore upstream timeout",
        "head": "agent/checkout-abc1234",
        "base": "build/demo",
        "body": "Cause: abc1234",
    }
    assert (pr.number, pr.node_id, pr.head_sha) == (7, "PR_node7", NEW_COMMIT)
    assert pr.url == f"https://github.test/{REPO}/pull/7"


@respx.mock(assert_all_mocked=True)
async def test_open_pr_blob_content_is_utf8_text(respx_mock, forge: GitHubForge) -> None:
    blobs, *_ = _mock_open_flow(respx_mock)
    await forge.open_pr("build/demo", "agent/checkout-x", "t", "b", {CONFIG: "k: \"é\"\n"}, "m")
    assert json.loads(blobs.calls[0].request.content) == {"content": "k: \"é\"\n", "encoding": "utf-8"}


@pytest.mark.parametrize("branch", ["feature/x", "promote/checkout", "build/demo", "agent", "agent/", "../agent/x"])
@respx.mock(assert_all_mocked=True)
async def test_branch_name_prefix_agent(respx_mock, forge: GitHubForge, branch: str) -> None:
    """The bridge only ever creates agent/<app>-* branches, and makes no call for any other name."""
    with pytest.raises(ValueError, match="agent/"):
        await forge.open_pr("build/demo", branch, "t", "b", {CONFIG: "x\n"}, "m")
    assert respx_mock.calls.call_count == 0


@respx.mock(assert_all_mocked=True)
async def test_open_pr_without_changes_is_refused(respx_mock, forge: GitHubForge) -> None:
    with pytest.raises(ValueError, match="changes"):
        await forge.open_pr("build/demo", "agent/checkout-x", "t", "b", {}, "m")
    assert respx_mock.calls.call_count == 0


@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_open_pr_existing_branch_conflict_raises(respx_mock, forge: GitHubForge) -> None:
    _, _, _, refs, pulls = _mock_open_flow(respx_mock, ref_status=422)
    with pytest.raises(ForgeConflict) as exc:
        await forge.open_pr("build/demo", "agent/checkout-x", "t", "b", {CONFIG: "x\n"}, "m")
    assert isinstance(exc.value, ForgeError) and exc.value.status == 422
    assert refs.call_count == 1
    assert pulls.call_count == 0


@respx.mock(assert_all_mocked=True)
async def test_open_pr_failure_removes_the_orphan_branch(respx_mock, forge: GitHubForge) -> None:
    """If the PR call fails after the ref exists, the branch is deleted so a retry can reuse the name."""
    _, _, _, _, pulls = _mock_open_flow(respx_mock)
    pulls.mock(return_value=httpx.Response(500))
    delete = respx_mock.delete(f"{BASE}/git/refs/heads/agent/checkout-x").mock(return_value=httpx.Response(204))
    with pytest.raises(ForgeError):
        await forge.open_pr("build/demo", "agent/checkout-x", "t", "b", {CONFIG: "x\n"}, "m")
    assert delete.call_count == 1


@respx.mock(assert_all_mocked=True)
async def test_open_pr_unknown_base_is_not_found(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/git/ref/heads/build/demo").mock(return_value=httpx.Response(404))
    with pytest.raises(ForgeNotFound):
        await forge.open_pr("build/demo", "agent/checkout-x", "t", "b", {CONFIG: "x\n"}, "m")


def _pr(number: int, ref: str, login: str) -> dict:
    return {
        "number": number,
        "html_url": f"https://github.test/{REPO}/pull/{number}",
        "node_id": f"PR_{number}",
        "state": "open",
        "head": {"ref": ref, "sha": f"{number:040x}"},
        "user": {"login": login},
    }


@respx.mock(assert_all_mocked=True)
async def test_list_open_agent_prs_filters_author_and_prefix(respx_mock, forge: GitHubForge) -> None:
    route = respx_mock.get(f"{BASE}/pulls").mock(
        return_value=httpx.Response(
            200,
            json=[
                _pr(1, "agent/checkout-abc1234", BOT),  # match
                _pr(2, "agent/checkout-abc1234", "someone-else"),  # right branch, wrong author
                _pr(3, "agent/pricing-abc1234", BOT),  # other app
                _pr(4, "agent/checkoutx-abc1234", BOT),  # app name is only a prefix of the word
                _pr(5, "promote/checkout", BOT),  # wrong prefix
                _pr(6, "feature/agent/checkout-1", BOT),  # prefix not at the start
                _pr(8, "agent/checkout-def5678", BOT),  # second match
            ],
        )
    )
    prs = await forge.list_open_agent_prs("checkout")
    assert [p.number for p in prs] == [1, 8]
    assert prs[0].url == f"https://github.test/{REPO}/pull/1"
    assert prs[0].node_id == "PR_1" and prs[0].head_sha == f"{1:040x}"
    params = route.calls[0].request.url.params
    assert params["state"] == "open"


@respx.mock(assert_all_mocked=True)
async def test_list_open_agent_prs_follows_pagination(respx_mock, forge: GitHubForge) -> None:
    page1 = [_pr(n, "feature/other", "someone") for n in range(1, 101)]
    page2 = [_pr(200, "agent/checkout-zzz", BOT)]
    route = respx_mock.get(f"{BASE}/pulls").mock(
        side_effect=lambda req: httpx.Response(200, json=page1 if req.url.params["page"] == "1" else page2)
    )
    assert [p.number for p in await forge.list_open_agent_prs("checkout")] == [200]
    assert route.call_count == 2


@respx.mock(assert_all_mocked=True)
async def test_list_open_agent_prs_custom_bot_login(respx_mock) -> None:
    respx_mock.get(f"{BASE}/pulls").mock(return_value=httpx.Response(200, json=[_pr(1, "agent/checkout-a", "my-bot[bot]")]))
    async with httpx.AsyncClient() as http:
        f = GitHubForge(REPO, StaticToken(), api_url=API, http=http, bot_login="my-bot[bot]")
        assert [p.number for p in await f.list_open_agent_prs("checkout")] == [1]


async def test_fake_forge_open_pr_and_list() -> None:
    fake = FakeForge()
    pr = await fake.open_pr("build/demo", "agent/checkout-a", "t", "b", {CONFIG: "x\n"}, "m")
    assert pr.number == 1 and pr.head_sha
    assert fake.opened[0].branch == "agent/checkout-a" and fake.opened[0].changes == {CONFIG: "x\n"}
    assert [p.number for p in await fake.list_open_agent_prs("checkout")] == [1]
    assert await fake.list_open_agent_prs("pricing") == []
    with pytest.raises(ForgeConflict):
        await fake.open_pr("build/demo", "agent/checkout-a", "t", "b", {CONFIG: "y\n"}, "m")
    with pytest.raises(ValueError):
        await fake.open_pr("build/demo", "main", "t", "b", {CONFIG: "y\n"}, "m")


@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_dry_forge_open_pr_sends_nothing_and_lists_through(respx_mock) -> None:
    writes = respx_mock.route(method__in=["POST", "PUT", "PATCH", "DELETE"]).mock(return_value=httpx.Response(500))
    respx_mock.get(f"{BASE}/pulls").mock(return_value=httpx.Response(200, json=[_pr(1, "agent/checkout-a", BOT)]))
    async with httpx.AsyncClient() as http:
        dry = DryForge(GitHubForge(REPO, StaticToken(), api_url=API, http=http))
        pr = await dry.open_pr("build/demo", "agent/checkout-a", "t", "b", {CONFIG: "x\n"}, "m")
        listed = await dry.list_open_agent_prs("checkout")
    assert writes.call_count == 0
    assert pr.url.startswith("dry-run:") and pr.number == 0
    assert [p.number for p in listed] == [1]
    assert dry.would == [("open pr", "agent/checkout-a")]


@respx.mock(assert_all_mocked=True)
async def test_branch_head_reads_the_ref(respx_mock, forge: GitHubForge) -> None:
    respx_mock.get(f"{BASE}/git/ref/heads/build/demo").mock(
        return_value=httpx.Response(200, json={"object": {"sha": BASE_SHA}})
    )
    assert await forge.branch_head("build/demo") == BASE_SHA


@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_open_pr_on_a_given_base_sha_uses_it_as_the_parent(respx_mock, forge: GitHubForge) -> None:
    """The fix is built from files read at one SHA; the commit's parent is that SHA, even if
    the branch has moved since, so a concurrent change is merged, never reverted."""
    _, _, commits, _, pulls = _mock_open_flow(respx_mock)
    await forge.open_pr("build/demo", "agent/checkout-x", "t", "b", {CONFIG: "x\n"}, "m", base_sha=BASE_SHA)
    commit_req = json.loads(commits.calls[0].request.content)
    assert commit_req["parents"] == [BASE_SHA]
    ref_calls = [c for c in respx_mock.calls if c.request.url.path.endswith("/git/ref/heads/build/demo")]
    assert ref_calls == []
    assert json.loads(pulls.calls[0].request.content)["base"] == "build/demo"


async def test_fake_and_dry_forge_branch_head_and_base_sha() -> None:
    fake = FakeForge(heads={"build/demo": SHA})
    assert await fake.branch_head("build/demo") == SHA
    await fake.open_pr("build/demo", "agent/checkout-a", "t", "b", {CONFIG: "x\n"}, "m", base_sha=SHA)
    assert fake.opened[0].base_sha == SHA
    assert await DryForge(fake).branch_head("build/demo") == SHA
