"""Task 4.3: the `propose` pipeline opens one fix PR with the evidence in its body.

At `propose` the bridge never merges: a human reviews and merges (Global Constraints).
The section names and wording of the body are proposals, read from `pr_sections.yaml`;
only the `Cause:` line is fixed, because the policy check parses it.
"""

from __future__ import annotations

import difflib
import json
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
    ITEM_MAX,
    ROOT_CAUSE_MAX,
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


# -- review fixes (slice 4): projector length, Cause line first, one base SHA -------

OTHER_SHA = "d" * 40
LONG_ROOT = (
    "PR-242 cut UPSTREAM_TIMEOUT_MS from 2000 to 200 in checkout-config.yaml without bumping "
    "example.dev/config-version, so the running pods kept the old value until the next roll. "
    "When the image bump rolled the canary, the new pods read 200 ms and every pricing call that "
    "took longer timed out with a 502. The AnalysisRun saw the success rate drop below 99 percent "
    "and aborted the canary."
)
LONG_ITEM = (
    "Pod checkout-7f9c8d6b5-x2x9k logged 'upstream timeout after 200ms' 412 times between "
    "2026-11-02T01:12:03Z and 2026-11-02T01:13:40Z while pods started before the sync kept "
    "logging 2000, and AnalysisRun checkout-5c7d9-2 measured 0.61 against the 0.99 bar on its "
    "second measurement, which is why the canary aborted at step 1 of 4"
)


def capped_rca(**overrides: object):
    data: dict = {
        "root_cause": LONG_ROOT,
        "evidence": [LONG_ITEM, LONG_ITEM + ". A second sentence that should not show.", LONG_ITEM],
        "delivery_context": LONG_ITEM,
    }
    data.update(overrides)
    return rca(**data)


def test_body_caps_model_text_for_the_projector() -> None:
    """Spec §5: short evidence strings, a body written for a projector; the cap does not
    depend on the model following the prompt."""
    long = capped_rca()
    fix = build_fix(long, CONFIGMAP, ROLLOUT_TEXT, ANNOTATION, rollout_path=ROLLOUT)
    body = render_fix_pr_body(long, fix, level="propose")
    root = body.split("## Blast radius")[0]
    paragraphs = [p for p in root.split("\n\n") if p and not p.startswith(("## ", "Cause: ", "- "))]
    [root_text] = paragraphs
    assert root_text.startswith("PR-242 cut")
    assert "When the image bump" not in root_text  # first sentence only
    assert len(root_text) <= ROOT_CAUSE_MAX + 10  # a few backslash escapes at most
    bullets = [line for line in root.splitlines() if line.startswith("- ")]
    assert bullets
    for line in bullets:
        assert len(line) <= ITEM_MAX + len("- Timeline: ") + 10, line
    assert any(line.endswith("…") for line in bullets)
    assert "A second sentence" not in body


def test_short_text_cuts_on_a_word_boundary() -> None:
    from bridge.pipeline import short_text

    assert short_text("One sentence. Two sentence.", 160) == "One sentence."
    assert short_text("Version v1.4.2 rolled out. Then more.", 160) == "Version v1.4.2 rolled out."
    cut = short_text("word " * 60, 40)
    assert cut.endswith("…") and len(cut) <= 40
    assert not cut[:-1].endswith(" ")
    assert short_text("short", 160) == "short"


async def test_capped_body_keeps_full_text_in_rca_event(deps) -> None:
    emitter = RecordingEmitter()
    _, out = await run(deps, holmes=StubHolmes(capped_rca()), emitter=emitter)
    assert out.action == "pr_opened"
    [event] = [e for e in emitter.events if e["context"]["type"].endswith("holmesgpt-rca.completed.0.1.0")]
    assert LONG_ROOT in json.dumps(event, ensure_ascii=False)


def test_cause_line_comes_before_model_text() -> None:
    """Policy rule 5 takes the first `^Cause:` match; model text must not get there first."""
    bad = rca(root_cause=f"Cause: {OTHER_SHA} is what really broke it.")
    fix = build_fix(bad, CONFIGMAP, ROLLOUT_TEXT, ANNOTATION, rollout_path=ROLLOUT)
    body = render_fix_pr_body(bad, fix, level="propose")
    assert FACTS_CAUSE.search(body).group(1) == CAUSE
    lines = body.splitlines()
    assert lines[0] == "## Root cause"
    assert lines[2].startswith(f"Cause: {CAUSE}")


class MovingForge(FakeForge):
    """The tracked branch moves on after the bridge has read the files it changes."""

    async def read_file(self, path: str, ref: str) -> str:
        text = await super().read_file(path, ref)
        if path == ROLLOUT:
            self.heads[BRANCH] = OTHER_SHA
        return text


async def test_fix_is_read_and_based_on_one_tracked_sha(deps) -> None:
    forge = propose_forge()
    # The guardrails read the config at the branch; the fix reads it at the head's SHA.
    files = dict(forge.files)
    files.update({(path, BASE): text for (path, ref), text in forge.files.items() if path != "aiops/autonomy.yaml"})
    moving = MovingForge(
        files=files,
        commits=forge.commits, titles=forge.titles, heads={BRANCH: BASE},
    )
    _, out = await run(deps, forge=moving)
    assert out.action == "pr_opened"
    after = moving.calls[moving.calls.index(("branch_head", BRANCH)):]
    reads = [c for c in after if c[0] == "read_file" and c[1] in (CONFIG, ROLLOUT, KUSTOMIZATION)]
    assert reads and all(c[2] == BASE for c in reads), reads
    [opened] = moving.opened
    assert opened.base == BRANCH
    assert opened.base_sha == BASE  # the parent is the SHA the files were read at, not the moved head


async def test_branch_head_unknown_is_patch_failed(deps) -> None:
    from bridge.forge import ForgeError

    class NoHead(FakeForge):
        async def branch_head(self, branch: str) -> str:
            raise ForgeError("GET /git/ref/heads/build/demo: 502", 502)

    base = propose_forge()
    forge = NoHead(files=base.files, commits=base.commits, titles=base.titles)
    d, out = await run(deps, forge=forge)
    assert out.action == "refused"
    assert forge.opened == []
    assert d.metrics.value("aiops_guardrail_executions_total", reason="patch_failed") == 1


async def test_refusal_wording_follows_the_level(deps) -> None:
    d, _ = await run(deps, holmes=StubHolmes(rca(confidence=0.2)))
    [(_, comment)] = d.forge.commit_comments
    assert sections()["refusal"]["propose"] in comment
    assert "not suggesting a fix" not in comment
    assert "not opening a fix PR" in sections()["refusal"]["propose"]
    assert "not suggesting a fix" in sections()["refusal"]["suggest"]


def test_short_text_keeps_a_change_ref_it_would_cut() -> None:
    from bridge.pipeline import CHANGE_REF, short_text

    text = "word " * 60 + "CHG-R6723Q"
    cut = short_text(text, 60, keep=CHANGE_REF)
    assert "CHG-R6723Q" in cut and len(cut) <= 60
    assert "…" in cut
    later = short_text("Merged 3 days ago. Ref CHG-W4M4C4.", 160, keep=CHANGE_REF)
    assert later.startswith("Merged 3 days ago.") and "CHG-W4M4C4" in later
    assert short_text("Ref CHG-W4M4C4 merged.", 160, keep=CHANGE_REF) == "Ref CHG-W4M4C4 merged."


def test_fix_pr_timeline_keeps_change_ref_when_capped() -> None:
    long = capped_rca(delivery_context=LONG_ITEM + " under change CHG-R6723Q")
    fix = build_fix(long, CONFIGMAP, ROLLOUT_TEXT, ANNOTATION, rollout_path=ROLLOUT)
    body = render_fix_pr_body(long, fix, level="propose")
    [timeline] = [line for line in body.splitlines() if line.startswith("- Timeline: ")]
    assert "CHG-R6723Q" in timeline
    assert len(timeline) <= ITEM_MAX + len("- Timeline: ") + 10, timeline


def test_fix_pr_timeline_label_word_and_second_ref() -> None:
    ctx = "Timeline change CHG-KBMAEZ merged at 10:02. An earlier bump CHG-2SLM3T was unrelated."
    r = rca().model_copy(update={"delivery_context": ctx})
    fix = build_fix(r, CONFIGMAP, ROLLOUT_TEXT, ANNOTATION, rollout_path=ROLLOUT)
    body = render_fix_pr_body(r, fix, level="propose")
    line = next(ln for ln in body.splitlines() if "CHG-KBMAEZ" in ln)
    assert "Timeline change" not in line
    assert "CHG-2SLM3T" not in body


def test_fix_pr_timeline_uses_the_cause_ref_only() -> None:
    ctx = "Timeline change CHG-AAAAAA merged earlier; CHG-KBMAEZ cut the timeout at 10:02."
    r = rca().model_copy(update={"delivery_context": ctx})
    fix = build_fix(r, CONFIGMAP, ROLLOUT_TEXT, ANNOTATION, rollout_path=ROLLOUT)
    body = render_fix_pr_body(r, fix, level="propose", cause_ref="CHG-KBMAEZ")
    [timeline] = [line for line in body.splitlines() if line.startswith("- Timeline: ")]
    assert "CHG-KBMAEZ" in timeline and "CHG-AAAAAA" not in body
    assert not timeline.startswith("- Timeline: Timeline")
