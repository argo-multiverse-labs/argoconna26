"""Task 3.5: the GitHub forge over REST, stubbed with respx; and DryForge."""

from __future__ import annotations

import base64
import json
import logging

import httpx
import pytest
import respx

from bridge.forge import DryForge, Forge, ForgeError, ForgeNotFound
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
