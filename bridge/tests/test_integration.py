"""Task 3.9 Step 1a (spec 10): the real app end to end, against stubbed HolmesGPT and GitHub.

The FastAPI app runs in-process through httpx's ASGITransport, from `POST /hooks/argocd`
through the worker, the real `HolmesClient`, the real `GitHubForge` and a real
`InstallationTokenProvider` (a throwaway key made in tmp_path). Every outbound call
hits a respx stub; nothing opens a socket.

HolmesGPT replays the recorded 0.45.0 responses (tests/fixtures/holmes). Their real
analyses are refused by the guardrails (confidence 0.6 and a free-text file; see the
fixtures README), so the refusal case replays `rca_ok.json` exactly as recorded, and
the comment case keeps the recorded envelope and tool calls and swaps in an analysis
the guardrails accept.
"""

from __future__ import annotations

import base64
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import pytest
import respx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from bridge import stagelog
from bridge.app import create_app
from bridge.config import Settings

from .conftest import BRIDGE_SOURCE, WEBHOOK_TOKEN, hook_body

FIXTURES = Path(__file__).parent / "fixtures" / "holmes"
GITHUB = "https://api.github.test"
REPO = "example-org/example-repo"
REPO_API = f"{GITHUB}/repos/{REPO}"
HOLMES = "http://holmes.test"
SINK = "http://cdevents.test/events"
INSTALLATION_ID = "987654"
INSTALLATION_TOKEN = "installation-token-for-tests"
BRANCH = "build/demo"
BASE = "1" * 40
CAUSE = "c" * 40
SYNC = "e" * 40
CONFIG = "apps/checkout/config/checkout-config.yaml"
AUTH = {"Authorization": f"Bearer {WEBHOOK_TOKEN}"}

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
GOOD_ANALYSIS = {
    "root_cause": "PR-242 cut UPSTREAM_TIMEOUT_MS to 200 without bumping config-version.",
    "cause_commit_sha": CAUSE,
    "evidence": [
        "Prometheus: pods started after the change report 200",
        "ConfigMap: checkout-config holds 200",
    ],
    "delivery_context": "CHG-7f3a merged 3 days before the abort as a config-only change.",
    "confidence": 0.9,
    "proposed_patch": {"file": CONFIG, "key": "UPSTREAM_TIMEOUT_MS", "from": "200", "to": "2000"},
}


def recorded(name: str) -> dict:
    raw = json.loads((FIXTURES / name).read_text())
    raw.pop("_fixture", None)
    return raw


def content(text: str) -> dict:
    return {"encoding": "base64", "content": base64.encodebytes(text.encode()).decode()}


@pytest.fixture
def key_path(tmp_path: Path) -> Path:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    path = tmp_path / "app-key"
    path.write_bytes(
        key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    )
    return path


@pytest.fixture
def settings(key_path: Path) -> Settings:
    return Settings(
        webhook_token=WEBHOOK_TOKEN,
        github_repo=REPO,
        github_api_url=GITHUB,
        tracked_branch=BRANCH,
        github_app_id="123456",
        github_installation_id=INSTALLATION_ID,
        github_app_key_path=str(key_path),
        holmes_url=HOLMES,
        holmes_api_key="holmes-test-key",
        holmes_timeout_s=5,
        cdevents_url=SINK,
        bridge_event_source=BRIDGE_SOURCE,
        argo_ui_url="http://127.0.0.1:30080",
    )


def body() -> dict:
    return hook_body(
        revision=SYNC,
        sync_revision=SYNC,
        history=[
            {"id": 1, "revision": BASE, "deployedAt": "2026-11-06T10:00:00Z"},
            {"id": 2, "revision": CAUSE, "deployedAt": "2026-11-06T11:00:00Z"},
            {"id": 3, "revision": SYNC, "deployedAt": "2026-11-09T17:40:00Z"},
        ],
    )


class World:
    """The stubbed outside world: GitHub, HolmesGPT and the cdevents sink."""

    def __init__(self, router: respx.Router, holmes: httpx.Response | Exception) -> None:
        expires = (datetime.now(UTC) + timedelta(hours=1)).isoformat()
        self.token = router.post(f"{GITHUB}/app/installations/{INSTALLATION_ID}/access_tokens").mock(
            return_value=httpx.Response(201, json={"token": INSTALLATION_TOKEN, "expires_at": expires})
        )
        router.get(f"{REPO_API}/contents/aiops/autonomy.yaml", params={"ref": BRANCH}).mock(
            return_value=httpx.Response(200, json=content(AUTONOMY))
        )
        router.get(f"{REPO_API}/contents/{CONFIG}", params={"ref": BRANCH}).mock(
            return_value=httpx.Response(200, json=content(CONFIGMAP))
        )
        router.get(f"{REPO_API}/commits/{CAUSE}").mock(
            return_value=httpx.Response(
                200, json={"sha": CAUSE, "commit": {"message": "PR-242: tune upstream timeout\n"}, "files": []}
            )
        )
        router.get(f"{REPO_API}/commits/{CAUSE}/pulls").mock(return_value=httpx.Response(200, json=[]))
        # Anything else under /commits or /compare is a commit GitHub doesn't know.
        router.get(url__regex=rf"^{REPO_API}/(commits|compare)/.*").mock(return_value=httpx.Response(404))
        self.comments = router.post(url__regex=rf"^{REPO_API}/commits/[0-9a-f]{{40}}/comments$").mock(
            side_effect=lambda request: httpx.Response(
                201, json={"html_url": f"https://github.test/{REPO}/commit/{request.url.path.split('/')[-2]}#c1"}
            )
        )
        self.pr_comments = router.post(url__regex=rf"^{REPO_API}/issues/\d+/comments$").mock(
            return_value=httpx.Response(201, json={"html_url": "https://github.test/pr#c"})
        )
        if isinstance(holmes, Exception):
            self.holmes = router.post(f"{HOLMES}/api/chat").mock(side_effect=holmes)
        else:
            self.holmes = router.post(f"{HOLMES}/api/chat").mock(return_value=holmes)
        self.sink = router.post(SINK).mock(return_value=httpx.Response(202, json={"id": "x"}))
        # Startup rehydrates the incident registry from open agent PRs (Task 4.3); none by default.
        self.open_prs = router.get(f"{REPO_API}/pulls").mock(return_value=httpx.Response(200, json=[]))
        self.readyz = router.get(f"{HOLMES}/readyz").mock(return_value=httpx.Response(200, text="ok"))

    def posted(self) -> list[tuple[str, str]]:
        """(commit sha, body) for every commit comment the bridge posted."""
        return [
            (call.request.url.path.split("/")[-2], json.loads(call.request.content)["body"])
            for call in self.comments.calls
        ]

    def events(self) -> list[dict]:
        return [json.loads(call.request.content) for call in self.sink.calls]


async def run_incident(settings: Settings) -> dict:
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://bridge.test") as client:
            r = await client.post("/hooks/argocd", json=body(), headers=AUTH)
            assert r.status_code == 202
            assert r.json()["status"] == "queued"
            await app.state.bridge.queue.join()  # the worker has finished the incident
            status = (await client.get("/status")).json()
            metrics = (await client.get("/metrics")).text
            replay = await client.post("/hooks/argocd", json=body(), headers=AUTH)
            assert replay.json()["status"] == "duplicate"
    return {"status": status, "metrics": metrics}


@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_suggest_end_to_end_comment_posted(respx_mock, settings: Settings, stage_lines) -> None:
    envelope = recorded("rca_toolcall_timeline.json")
    envelope["analysis"] = json.dumps(GOOD_ANALYSIS)
    world = World(respx_mock, httpx.Response(200, json=envelope))

    result = await run_incident(settings)

    [(sha, comment)] = world.posted()
    assert sha == CAUSE
    assert comment.startswith("## Root cause\n")
    assert f"Cause: {CAUSE} (PR-242: tune upstream timeout)" in comment.splitlines()
    assert "- Timeline: CHG-7f3a merged 3 days before the abort as a config-only change." in comment
    # The installation token was minted once and used on every GitHub call.
    assert world.token.call_count == 1
    for call in world.comments.calls:
        assert call.request.headers["Authorization"] == f"Bearer {INSTALLATION_TOKEN}"
    # HolmesGPT got the strict request, and its recorded tool call reached the stage log.
    request = json.loads(world.holmes.calls[0].request.content)
    assert request["response_format"]["json_schema"]["strict"] is True
    assert stage_lines == [
        "▸ webhook: checkout degraded",
        "▸ autonomy: suggest",
        "▸ holmes: investigating",
        "▸ holmes: GET /timeline",
        "▸ guardrails: passed",
        "▸ pii: clean",
        "▸ suggest: commented",
    ]
    # Events and status.
    types = [e["context"]["type"] for e in world.events()]
    assert types == ["dev.cdeventsx.holmesgpt-rca.completed.0.1.0", "dev.cdeventsx.agent-action.0.1.0"]
    assert {e["context"]["source"] for e in world.events()} == {BRIDGE_SOURCE}
    assert result["status"]["level_last_seen"] == "suggest"
    assert result["status"]["last_incident"]["action"] == "commented"
    assert result["status"]["last_incident"]["holmes_failed"] is False
    assert 'aiops_actions_total{action="commented"} 1.0' in result["metrics"]
    assert 'aiops_human_touchpoints{level="suggest"} 4.0' in result["metrics"]


@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_suggest_end_to_end_refusal(respx_mock, settings: Settings) -> None:
    # The recorded real-Claude answer, unchanged: confidence 0.6, a SHA GitHub doesn't
    # know and a free-text file. The guardrails refuse it on all three counts.
    world = World(respx_mock, httpx.Response(200, json=recorded("rca_ok.json")))

    result = await run_incident(settings)

    [(sha, comment)] = world.posted()
    assert sha == SYNC  # the cause is unknown, so the refusal goes on the synced revision
    assert "## Root cause" not in comment
    for reason in ("low_confidence", "cause_not_in_history", "file_not_allowed"):
        assert reason in comment
        assert f'aiops_guardrail_executions_total{{reason="{reason}"}} 1.0' in result["metrics"]
    actions = [e for e in world.events() if e["context"]["type"] == "dev.cdeventsx.agent-action.0.1.0"]
    assert [a["customData"]["action"] for a in actions] == ["refused"]
    assert result["status"]["last_incident"]["action"] == "refused"


@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_holmes_timeout_end_to_end_handoff(respx_mock, settings: Settings) -> None:
    world = World(respx_mock, httpx.ReadTimeout("no answer"))

    result = await run_incident(settings)

    assert world.posted() == [
        (SYNC, f"Investigation did not finish in {settings.holmes_timeout_s:g} s; a human should take this one.")
    ]
    assert [e["customData"]["action"] for e in world.events()] == ["holmes_failed"]
    assert result["status"]["last_incident"]["holmes_failed"] is True
    assert result["status"]["last_incident"]["action"] == "holmes_failed"


@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_several_tool_calls_with_errors_end_to_end(respx_mock, settings: Settings, stage_lines) -> None:
    # O14: a refused call and a successful one in the same investigation (both recorded).
    envelope = recorded("rca_toolcall_timeline.json")
    envelope["tool_calls"] = recorded("rca_toolcall_refused_events.json")["tool_calls"] + envelope["tool_calls"]
    envelope["analysis"] = json.dumps(GOOD_ANALYSIS)
    world = World(respx_mock, httpx.Response(200, json=envelope))

    result = await run_incident(settings)

    assert result["status"]["last_incident"]["action"] == "commented"
    assert len(world.posted()) == 1
    holmes = [line for line in stage_lines if line.startswith("▸ holmes:")]
    assert holmes == [
        "▸ holmes: investigating",
        stagelog.line("holmes", "GET /events (refused)", settings.stage_cols),
        "▸ holmes: GET /timeline",
    ]


async def started_status(settings: Settings) -> dict:
    """/status and /metrics once the startup refresh has run, before any webhook."""
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        await app.state.bridge.refreshed.wait()  # the first refresh has finished
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://bridge.test") as client:
            status = (await client.get("/status")).json()
            metrics = (await client.get("/metrics")).text
    return {"status": status, "metrics": metrics}


@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_startup_sets_touchpoints_and_probes_before_any_incident(respx_mock, settings: Settings, caplog) -> None:
    world = World(respx_mock, httpx.Response(500))

    result = await started_status(settings)

    assert 'aiops_human_touchpoints{level="suggest"} 4.0' in result["metrics"]
    assert 'aiops_human_touchpoints{level="act"} 1.0' in result["metrics"]
    assert result["status"]["github_token_ok"] is True
    assert result["status"]["holmes_reachable"] is True
    assert result["status"]["last_incident"] is None
    assert world.readyz.call_count == 1
    assert world.holmes.call_count == 0  # no LLM call at startup
    assert INSTALLATION_TOKEN not in caplog.text


@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_startup_probes_report_failures(respx_mock, settings: Settings) -> None:
    world = World(respx_mock, httpx.Response(500))
    world.token.mock(return_value=httpx.Response(401, json={"message": "Bad credentials"}))
    world.readyz.mock(return_value=httpx.Response(503))

    result = await started_status(settings)

    assert result["status"]["github_token_ok"] is False
    assert result["status"]["holmes_reachable"] is False
    # The autonomy file could not be read, so no touchpoints are made up.
    assert "aiops_human_touchpoints{" not in result["metrics"]


@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_unreadable_key_reports_token_not_ok(respx_mock, settings: Settings, key_path: Path) -> None:
    World(respx_mock, httpx.Response(500))
    key_path.chmod(0)
    try:
        result = await started_status(settings)
    finally:
        key_path.chmod(0o600)
    assert result["status"]["github_token_ok"] is False


@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_holmes_connection_error_is_not_reachable(respx_mock, settings: Settings) -> None:
    world = World(respx_mock, httpx.Response(500))
    world.readyz.mock(side_effect=httpx.ConnectError("refused"))
    result = await started_status(settings)
    assert result["status"]["holmes_reachable"] is False


ROLLOUT = "apps/checkout/deploy/rollout.yaml"
KUSTOMIZATION = "apps/checkout/kustomization.yaml"
ROLLOUT_TEXT = """\
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: checkout
spec:
  template:
    metadata:
      annotations:
        example.dev/config-version: "7"
"""
KUSTOMIZATION_TEXT = """\
images:
  - name: checkout
    newTag: v1.4.2
"""
TRACKED_HEAD = "f" * 40


@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_propose_end_to_end_opens_pr(respx_mock, settings: Settings, stage_lines) -> None:
    """Git Data API and `POST /pulls` stubbed: one commit with two files, one PR, no merge call."""
    envelope = recorded("rca_toolcall_timeline.json")
    envelope["analysis"] = json.dumps(GOOD_ANALYSIS)
    world = World(respx_mock, httpx.Response(200, json=envelope))
    respx_mock.get(f"{REPO_API}/contents/aiops/autonomy.yaml", params={"ref": BRANCH}).mock(
        return_value=httpx.Response(200, json=content(AUTONOMY.replace("level: suggest", "level: propose")))
    )
    # The fix's files are read at the tracked head's SHA, which becomes the commit's parent.
    respx_mock.get(f"{REPO_API}/contents/{CONFIG}", params={"ref": TRACKED_HEAD}).mock(
        return_value=httpx.Response(200, json=content(CONFIGMAP))
    )
    respx_mock.get(f"{REPO_API}/contents/{ROLLOUT}", params={"ref": TRACKED_HEAD}).mock(
        return_value=httpx.Response(200, json=content(ROLLOUT_TEXT))
    )
    respx_mock.get(f"{REPO_API}/contents/{KUSTOMIZATION}", params={"ref": TRACKED_HEAD}).mock(
        return_value=httpx.Response(200, json=content(KUSTOMIZATION_TEXT))
    )
    respx_mock.get(f"{REPO_API}/git/ref/heads/{BRANCH}").mock(
        return_value=httpx.Response(200, json={"object": {"sha": TRACKED_HEAD}})
    )
    respx_mock.get(f"{REPO_API}/git/commits/{TRACKED_HEAD}").mock(
        return_value=httpx.Response(200, json={"sha": TRACKED_HEAD, "tree": {"sha": "t" * 40}})
    )
    blobs = respx_mock.post(f"{REPO_API}/git/blobs").mock(return_value=httpx.Response(201, json={"sha": "b" * 40}))
    trees = respx_mock.post(f"{REPO_API}/git/trees").mock(return_value=httpx.Response(201, json={"sha": "d" * 40}))
    commits = respx_mock.post(f"{REPO_API}/git/commits").mock(
        return_value=httpx.Response(201, json={"sha": "9" * 40})
    )
    refs = respx_mock.post(f"{REPO_API}/git/refs").mock(return_value=httpx.Response(201, json={}))
    pr_url = f"https://github.test/{REPO}/pull/7"
    pulls = respx_mock.post(f"{REPO_API}/pulls").mock(
        return_value=httpx.Response(
            201, json={"number": 7, "html_url": pr_url, "node_id": "PR_7", "head": {"sha": "9" * 40}}
        )
    )
    merge = respx_mock.put(url__regex=rf"^{REPO_API}/pulls/\d+/merge$").mock(return_value=httpx.Response(200))
    graphql = respx_mock.post(f"{GITHUB}/graphql").mock(return_value=httpx.Response(200, json={}))

    result = await run_incident(settings)

    assert result["status"]["level_last_seen"] == "propose"
    assert result["status"]["last_incident"]["action"] == "pr_opened"
    assert result["status"]["last_incident"]["url"] == pr_url
    assert blobs.call_count == 2
    [tree_call] = trees.calls
    assert sorted(e["path"] for e in json.loads(tree_call.request.content)["tree"]) == [CONFIG, ROLLOUT]
    assert commits.call_count == 1
    assert json.loads(commits.calls[0].request.content)["parents"] == [TRACKED_HEAD]
    [ref_call] = refs.calls
    assert json.loads(ref_call.request.content)["ref"] == f"refs/heads/agent/checkout-{CAUSE[:7]}-{SYNC[:7]}"
    [pull_call] = pulls.calls
    pr = json.loads(pull_call.request.content)
    assert pr["base"] == BRANCH
    assert pr["title"] == "fix(checkout): restore UPSTREAM_TIMEOUT_MS to 2000 and roll config"
    assert f"Cause: {CAUSE} (PR-242: tune upstream timeout)" in pr["body"].splitlines()
    assert "v1.4.2" in pr["body"]
    assert merge.call_count == 0 and graphql.call_count == 0  # a human merges at propose
    assert world.posted() == [] and world.pr_comments.call_count == 0
    types = [e["context"]["type"] for e in world.events()]
    assert "dev.cdevents.change.created.0.4.0" in types
    assert 'aiops_actions_total{action="pr_opened"} 1.0' in result["metrics"]
    assert stage_lines[-1] == "▸ propose: pr opened"
