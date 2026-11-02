"""Task 4.3: the `propose` pipeline opens one fix PR with the evidence in its body.

At `propose` the bridge never merges: a human reviews and merges (Global Constraints).
The section names and wording of the body are proposals, read from `pr_sections.yaml`;
only the `Cause:` line is fixed, because the policy check parses it.
"""

from __future__ import annotations

import difflib
import re
import threading
from importlib import resources

import pytest
import yaml
from fastapi.testclient import TestClient

from bridge.app import Probes, create_app
from bridge.forge.base import PullRequest
from bridge.forge.fake import FakeForge
from bridge.incidents import IncidentRegistry
from bridge.metrics import Metrics
from bridge.models import ArgoDegradedHook
from bridge.patch import build_fix
from bridge.pipeline import (
    Deps,
    handle_incident,
    rehydrate_registry,
    render_fix_pr_body,
)

from .conftest import WEBHOOK_TOKEN, hook_body
from .test_pipeline_suggest import (
    AUTONOMY,
    BASE,
    BRANCH,
    CAUSE,
    CONFIG,
    CONFIGMAP,
    NOW,
    SYNC,
    RecordingEmitter,
    StubHolmes,
    make_hook,
    rca,
)

ROLLOUT = "apps/checkout/deploy/rollout.yaml"
KUSTOMIZATION = "apps/checkout/kustomization.yaml"
ANNOTATION = "example.dev/config-version"
BRANCH_NAME = f"agent/checkout-{CAUSE[:7]}-{SYNC[:7]}"
TITLE = "fix(checkout): restore UPSTREAM_TIMEOUT_MS to 2000 and roll config"
FACTS_CAUSE = re.compile(r"^Cause: ([0-9a-f]{40})\b", re.MULTILINE)  # policy/facts/facts.py's regex
CHANGE_CREATED = "dev.cdevents.change.created.0.4.0"

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
    spec:
      containers:
        - name: checkout
          image: checkout
"""

KUSTOMIZATION_TEXT = """\
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
images:
  - name: checkout
    newTag: v1.4.3
"""


@pytest.fixture
def deps(settings):
    def build(holmes: StubHolmes | None = None, forge: FakeForge | None = None, emitter=None) -> Deps:
        return Deps(
            forge=forge or propose_forge(),
            holmes=holmes or StubHolmes(rca()),
            emitter=emitter if emitter is not None else RecordingEmitter(),
            settings=settings,
            registry=IncidentRegistry(),
            clock=lambda: NOW,
            metrics=Metrics(),
        )

    return build


def sections() -> dict:
    text = resources.files("bridge").joinpath("templates/pr_sections.yaml").read_text()
    return yaml.safe_load(text)


def propose_forge(**overrides: object) -> FakeForge:
    forge = FakeForge(
        files={
            ("aiops/autonomy.yaml", BRANCH): AUTONOMY.replace("level: suggest", "level: propose"),
            (CONFIG, BRANCH): CONFIGMAP,
            (ROLLOUT, BRANCH): ROLLOUT_TEXT,
            (KUSTOMIZATION, BRANCH): KUSTOMIZATION_TEXT,
        },
        commits=[BASE, CAUSE, SYNC],
        titles={CAUSE: "PR-242: tune upstream timeout for faster failover", SYNC: "checkout v1.4.2"},
    )
    for key, value in overrides.items():
        setattr(forge, key, value)
    return forge


def existing_pr(forge: FakeForge, branch: str) -> PullRequest:
    """An agent PR opened before this incident (by an earlier one, or before a restart)."""
    n = len(forge.opened) + 1
    pr = PullRequest(n, f"https://forge.test/pull/{n}", f"PR_{n}", f"{n:040x}", branch)
    from bridge.forge.fake import OpenedPR

    forge.opened.append(OpenedPR(BRANCH, branch, "earlier", "body", {CONFIG: "x"}, "msg", pr))
    return pr


def changed_lines(before: str, after: str) -> list[str]:
    return [
        line
        for line in difflib.unified_diff(before.splitlines(), after.splitlines(), lineterm="", n=0)
        if line[:1] in "+-" and not line.startswith(("+++", "---"))
    ]


async def run(deps, forge: FakeForge | None = None, holmes: StubHolmes | None = None, emitter=None):
    d = deps(forge=forge or propose_forge(), holmes=holmes, emitter=emitter)
    out = await handle_incident(make_hook(), d)
    return d, out


def body_of(forge: FakeForge) -> str:
    [opened] = forge.opened
    return opened.body


# -- the PR itself ------------------------------------------------------------


async def test_propose_opens_pr_with_two_changes(deps) -> None:
    d, out = await run(deps)
    forge = d.forge
    assert out.action == "pr_opened"
    assert out.level == "propose"
    [opened] = forge.opened
    assert opened.base == BRANCH
    assert opened.branch == BRANCH_NAME
    assert opened.title == TITLE
    assert set(opened.changes) == {CONFIG, ROLLOUT}
    total = len(changed_lines(CONFIGMAP, opened.changes[CONFIG])) + len(
        changed_lines(ROLLOUT_TEXT, opened.changes[ROLLOUT])
    )
    assert total == 4  # two lines changed: each is one '-' and one '+'
    assert 'UPSTREAM_TIMEOUT_MS: "2000"' in opened.changes[CONFIG]
    assert 'example.dev/config-version: "8"' in opened.changes[ROLLOUT]
    assert opened.commit_message.splitlines()[0] == TITLE
    assert out.url == opened.pr.url
    assert forge.commit_comments == [] and forge.pr_comments == []
    assert d.metrics.value("aiops_actions_total", action="pr_opened") == 1


async def test_propose_never_merges(deps) -> None:
    class MergeRecordingForge(FakeForge):
        merges: list[str]

        async def merge_pr(self, *args: object, **kwargs: object) -> None:
            self.calls.append(("merge_pr",))

        async def enable_auto_merge(self, *args: object, **kwargs: object) -> None:
            self.calls.append(("enable_auto_merge",))

    forge = MergeRecordingForge(**{k: getattr(propose_forge(), k) for k in ("files", "commits", "titles")})
    _, out = await run(deps, forge=forge)
    assert out.action == "pr_opened"
    names = {call[0] for call in forge.calls}
    assert "open_pr" in names
    assert not names & {"merge_pr", "enable_auto_merge"}


async def test_change_created_event_emitted_with_pr_url(deps) -> None:
    emitter = RecordingEmitter()
    d, out = await run(deps, emitter=emitter)
    created = [e for e in emitter.events if e["context"]["type"] == CHANGE_CREATED]
    assert len(created) == 1
    assert created[0]["customData"]["pr_url"] == out.url
    assert created[0]["customData"]["branch"] == BRANCH_NAME
    assert created[0]["customData"]["app"] == "checkout"
    assert created[0]["context"]["source"] == d.settings.bridge_event_source
    actions = [e["customData"]["action"] for e in emitter.events if e["context"]["type"].endswith("agent-action.0.1.0")]
    assert actions == ["pr_opened"]


async def test_propose_stage_lines_short_and_shaless(deps, stage_lines: list[str]) -> None:
    d, _ = await run(deps)
    assert "▸ propose: pr opened" in stage_lines
    for line in stage_lines:
        assert len(line) <= d.settings.stage_cols
        assert not re.search(r"[0-9a-f]{7,}", line), line


# -- the body ---------------------------------------------------------------


async def test_body_sections_present_and_short(deps) -> None:
    d, _ = await run(deps)
    body = body_of(d.forge)
    names = sections()["sections"]
    headings = [line[3:] for line in body.splitlines() if line.startswith("## ")]
    assert headings == [names["root_cause"], names["blast_radius"], names["evidence"]]

    root = body.split(f"## {names['blast_radius']}")[0]
    bullets = [line for line in root.splitlines() if line.startswith("- ")]
    assert 1 <= len(bullets) <= 3
    assert any("CHG-7f3a merged 3 days before the abort" in b for b in bullets)  # delivery context

    blast = body.split(f"## {names['blast_radius']}")[1].split("## ")[0]
    assert "v1.4.3" in blast  # the image tag from kustomization.yaml
    assert "UPSTREAM_TIMEOUT_MS" in blast and CONFIG in blast
    assert "7→8" in blast

    details = re.search(r"<details>.*?</details>", body, re.DOTALL)
    assert details, "the revisions table sits in a collapsed <details> block"
    rows = [line for line in details.group(0).splitlines() if line.startswith("| ") and "`" in line]
    assert 1 <= len(rows) <= 5
    assert f"`{SYNC[:7]}`" in details.group(0)
    assert SYNC not in details.group(0)  # short SHAs only

    visible = body.split("<details>")[0]
    assert len([line for line in visible.splitlines() if line.strip()]) <= 16  # fits a projector


async def test_body_contains_full_cause_sha_line(deps) -> None:
    d, _ = await run(deps)
    body = body_of(d.forge)
    m = FACTS_CAUSE.search(body)
    assert m and m.group(1) == CAUSE
    assert f"Cause: {CAUSE} (PR-242: tune upstream timeout for faster failover)" in body.splitlines()


async def test_propose_footer_states_human_merge(deps) -> None:
    d, _ = await run(deps)
    body = body_of(d.forge)
    footer = sections()["footer"]["propose"]
    assert body.rstrip().splitlines()[-1] == footer
    assert "A human reviews and merges." in footer


def test_act_footer_states_policy_check_and_after_the_fact_review() -> None:
    fix = build_fix(rca(), CONFIGMAP, ROLLOUT_TEXT, ANNOTATION, rollout_path=ROLLOUT)
    body = render_fix_pr_body(rca(), fix, level="act")
    assert body.rstrip().splitlines()[-1] == sections()["footer"]["act"]
    assert "policy-check" in body


def test_render_with_only_rca_fix_and_level() -> None:
    """The signature Task 4.2's policy test (enabled in Task 5.2) calls."""
    fix = build_fix(rca(), CONFIGMAP, ROLLOUT_TEXT, ANNOTATION, rollout_path=ROLLOUT)
    body = render_fix_pr_body(rca(), fix, level="propose")
    assert FACTS_CAUSE.search(body).group(1) == CAUSE
    assert "<details>" not in body or "|" in body


def test_blast_radius_mentions_security_fix_only_from_the_cve_tag(settings) -> None:
    fix = build_fix(rca(), CONFIGMAP, ROLLOUT_TEXT, ANNOTATION, rollout_path=ROLLOUT)
    with_fix = render_fix_pr_body(rca(), fix, level="propose", image_tag="v1.4.3", cve_tag="v1.4.2")
    without = render_fix_pr_body(rca(), fix, level="propose", image_tag="v1.4.1", cve_tag="v1.4.2")
    assert "v1.4.2 security fix" in with_fix
    assert "security fix" not in without
    assert "v1.4.1" in without


def test_body_model_text_cannot_mention_or_link() -> None:
    bad = rca(root_cause="Ping @payments-team, see https://evil.example and #12")
    fix = build_fix(bad, CONFIGMAP, ROLLOUT_TEXT, ANNOTATION, rollout_path=ROLLOUT)
    body = render_fix_pr_body(bad, fix, level="propose")
    assert "@payments-team" not in body
    assert "https://evil" not in body
    assert " #12" not in body


# -- gates ------------------------------------------------------------------


async def test_pii_in_body_blocks_pr(deps) -> None:
    holmes = StubHolmes(rca(root_cause="Owner jane.doe@example.com cut the timeout to 200."))
    d, out = await run(deps, holmes=holmes)
    assert out.action == "pii_blocked"
    assert d.forge.opened == []
    [(sha, comment)] = d.forge.commit_comments
    assert sha == SYNC
    assert "jane.doe" not in comment
    assert d.metrics.value("aiops_pii_leaks_caught_total", kind="email") == 1


async def test_refusal_at_propose_posts_comment_not_pr(deps) -> None:
    d, out = await run(deps, holmes=StubHolmes(rca(confidence=0.2)))
    assert out.action == "refused"
    assert out.level == "propose"
    assert d.forge.opened == []
    [(sha, comment)] = d.forge.commit_comments
    assert sha == CAUSE
    assert "low_confidence" in comment
    assert d.metrics.value("aiops_guardrail_executions_total", reason="low_confidence") == 1


async def test_patch_that_cannot_be_built_is_refused_not_opened(deps) -> None:
    forge = propose_forge()
    forge.files[(ROLLOUT, BRANCH)] = ROLLOUT_TEXT.replace('example.dev/config-version: "7"', "other: x")
    d, out = await run(deps, forge=forge)
    assert out.action == "refused"
    assert forge.opened == []
    [(_, comment)] = forge.commit_comments
    assert "patch_failed" in comment
    assert d.metrics.value("aiops_guardrail_executions_total", reason="patch_failed") == 1


async def test_open_pr_failure_is_post_failed(deps) -> None:
    from bridge.forge import ForgeError

    forge = propose_forge(fail_writes=ForgeError("POST /pulls: 502", 502))
    d, out = await run(deps, forge=forge)
    assert out.action == "pr_opened"
    assert out.post_failed is True
    assert out.url is None
    assert d.metrics.value("aiops_actions_total", action="post_failed") == 1


# -- idempotency (Review Focus 5) ---------------------------------------------


async def test_open_agent_pr_for_app_blocks_new_pr(deps) -> None:
    forge = propose_forge()
    earlier = existing_pr(forge, f"agent/checkout-{CAUSE[:7]}-{BASE[:7]}")
    holmes = StubHolmes(rca())
    _, out = await run(deps, forge=forge, holmes=holmes)
    assert out.action == "duplicate"
    assert len(forge.opened) == 1  # only the earlier one
    [(number, comment)] = forge.pr_comments
    assert number == earlier.number
    assert comment == f"Another degraded revision {SYNC} seen; see this PR."
    assert holmes.prompts == []  # no LLM spend on a blocked incident


async def test_replay_of_the_open_prs_own_revision_posts_nothing(deps) -> None:
    forge = propose_forge()
    existing_pr(forge, BRANCH_NAME)
    _, out = await run(deps, forge=forge)
    assert out.action == "duplicate"
    assert forge.pr_comments == [] and forge.commit_comments == []
    assert len(forge.opened) == 1


async def test_branch_already_exists_is_duplicate_not_failure(deps) -> None:
    forge = propose_forge()
    existing_pr(forge, BRANCH_NAME)

    async def none(app: str | None = None) -> list[PullRequest]:
        return []  # the PR was closed, but its branch was left behind

    forge.list_open_agent_prs = none  # type: ignore[method-assign]
    _, out = await run(deps, forge=forge)
    assert out.action == "duplicate"
    assert out.post_failed is False


async def test_rehydrate_registry_from_open_pr_branches() -> None:
    forge = propose_forge()
    existing_pr(forge, BRANCH_NAME)
    existing_pr(forge, "agent/spike-1793567337")  # not an incident branch: ignored
    registry = IncidentRegistry()
    assert await rehydrate_registry(registry, forge) == 1
    assert registry.seen(f"checkout@{SYNC}")
    assert not registry.seen(f"checkout@{BASE}")
    assert not registry.mark_if_new(f"checkout@{SYNC}")
    assert registry.mark_if_new(f"pricing@{SYNC}")


def test_rehydrate_from_open_prs_prevents_duplicate_after_restart(settings) -> None:
    """A fresh bridge (empty registry) reads the open agent PRs before it takes a webhook."""
    forge = propose_forge()
    existing_pr(forge, BRANCH_NAME)
    calls: list[ArgoDegradedHook] = []
    done = threading.Event()

    async def handler(hook: ArgoDegradedHook) -> None:
        calls.append(hook)
        done.set()

    app = create_app(settings, handler=handler, probes=Probes(forge=forge))
    auth = {"Authorization": f"Bearer {WEBHOOK_TOKEN}"}
    with TestClient(app) as client:
        replay = client.post("/hooks/argocd", json=hook_body(revision=SYNC, sync_revision=SYNC), headers=auth)
        assert replay.json()["status"] == "duplicate"
        fresh = client.post("/hooks/argocd", json=hook_body(revision=BASE, sync_revision=BASE), headers=auth)
        assert fresh.json()["status"] == "queued"
        assert done.wait(timeout=5)
        client.portal.call(client.app.state.bridge.queue.join)
    assert [h.revision for h in calls] == [BASE]


def test_rehydrate_failure_does_not_stop_startup(settings) -> None:
    from bridge.forge import ForgeError

    forge = propose_forge(fail_reads=ForgeError("GET /pulls: 500", 500))
    app = create_app(settings, handler=lambda hook: None, probes=Probes(forge=forge))
    with TestClient(app) as client:
        assert client.get("/healthz").text == "ok"


@pytest.mark.parametrize("branch", ["agent/checkout-ccccccc-eeeeeee", "agent/my-app-ccccccc-eeeeeee"])
async def test_rehydrate_parses_app_names_with_hyphens(branch: str) -> None:
    forge = propose_forge()
    existing_pr(forge, branch)
    registry = IncidentRegistry()
    await rehydrate_registry(registry, forge)
    app = branch.removeprefix("agent/").rsplit("-", 2)[0]
    assert registry.seen(f"{app}@{SYNC}")


async def test_title_breaks_references_in_model_values(deps) -> None:
    holmes = StubHolmes(rca(proposed_patch={"file": CONFIG, "key": "UPSTREAM_TIMEOUT_MS", "from": "200", "to": "#12"}))
    d, _ = await run(deps, holmes=holmes)
    [opened] = d.forge.opened
    assert "#12" not in opened.title
    assert "#12" not in opened.commit_message
    assert "#\u200b12" in opened.title


async def test_bot_login_from_settings_reaches_the_forge(settings, tmp_path) -> None:
    import httpx

    from bridge.app import build_pipeline
    from bridge.metrics import Metrics

    configured = settings.model_copy(
        update={"github_app_id": "1", "github_installation_id": "2", "github_app_key_path": str(tmp_path / "k"),
                "bot_login": "someone-else[bot]"}
    )
    async with httpx.AsyncClient() as http:
        _, probes = build_pipeline(configured, IncidentRegistry(), Metrics(), http)
    assert probes.forge.bot_login == "someone-else[bot]"


def test_settings_read_the_fix_pr_names_from_the_environment(monkeypatch) -> None:
    from bridge.config import Settings

    monkeypatch.setenv("ROLLOUT_FILE", "apps/x/deploy/rollout.yaml")
    monkeypatch.setenv("KUSTOMIZATION_FILE", "apps/x/kustomization.yaml")
    monkeypatch.setenv("CHECKOUT_CVE_TAG", "v9.9.9")
    monkeypatch.setenv("BOT_LOGIN", "x[bot]")
    s = Settings()
    assert (s.rollout_file, s.kustomization_file, s.cve_fix_tag, s.bot_login) == (
        "apps/x/deploy/rollout.yaml", "apps/x/kustomization.yaml", "v9.9.9", "x[bot]"
    )
