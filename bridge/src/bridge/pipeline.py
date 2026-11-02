"""One incident, start to finish: autonomy → HolmesGPT → guardrails → render → PII gate → act → events.

`suggest` comments the RCA on the cause's PR, or on the cause commit. `propose`
opens one fix PR (two lines, built by `patch.build_fix`) with the RCA and evidence
in its body, and never merges it: a human reviews and merges. `act` (Task 5.4) opens
the same PR and enables auto-merge, so GitHub merges it once the required `policy-check`
passes. When GitHub says the PR can merge right now (`clean_status`: no required check
holds it), the bridge waits for `policy-check` itself and merges only on `success`.

Model text leaves the bridge in the comment or the fix PR (title, body, commit
message) and in the `rca_completed` event. All of it is PII-scanned before anything
is sent, and a hit blocks all of it (spec 7.1). Nothing posted on a refusal, a block
or a HolmesGPT failure is model text except the refusal's details, which are scanned
the same way.
"""

from __future__ import annotations

import asyncio
import functools
import json
import logging
import re
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from importlib import resources
from typing import Any, Literal, Protocol

import yaml
from jinja2 import Environment, PackageLoader, StrictUndefined

from . import events, guardrails, pii, stagelog
from .autonomy import Level, read_autonomy
from .config import Settings
from .events import Emitter
from .forge import (
    CheckStatus,
    Forge,
    ForgeConflict,
    ForgeError,
    MergeMethod,
    PullRequest,
)
from .guardrails import Refusal
from .holmes import HolmesError, HolmesResult, HolmesTimeout
from .incidents import SHORT_REVISION, IncidentRegistry
from .metrics import Metrics
from .models import ArgoDegradedHook, HistoryEntry
from .patch import FixChange, PatchError, build_fix
from .prompt import build_prompt, live_window
from .rca import RCA

log = logging.getLogger("bridge.pipeline")

Action = Literal[
    "commented", "refused", "pii_blocked", "holmes_failed", "pr_opened", "auto_merge_enabled", "merged",
    "policy_failed", "duplicate",
]
EVIDENCE_BULLETS = 2  # plus the Timeline bullet: at most three on the projector
# Spec §5: short evidence strings, a body written for a projector. Model text in the fix PR
# and the rung-1 comment is cut to its first sentence and to these lengths, whatever the prompt
# got back; the full text stays in the rca.completed event.
ROOT_CAUSE_MAX = 200
ITEM_MAX = 160
REVISIONS_SHOWN = 5  # the fix PR's synced-revisions table
ANOTHER_REVISION = "Another degraded revision {revision} seen; see this PR."
REHYDRATE_TIMEOUT_S = 15.0
TIMEOUT_HANDOFF = "Investigation did not finish in {timeout:g} s; a human should take this one."
BAD_OUTPUT_HANDOFF = "Investigation did not return a usable answer; a human should take this one."


class Holmes(Protocol):
    async def investigate(self, prompt: str) -> HolmesResult: ...


def _utcnow() -> datetime:
    return datetime.now(UTC)


class ChangeRefs(Protocol):
    async def change_ref(self, app: str, sha: str) -> str | None: ...


@dataclass
class Deps:
    forge: Forge
    holmes: Holmes
    emitter: Emitter
    settings: Settings
    registry: IncidentRegistry
    clock: Callable[[], datetime] = _utcnow
    metrics: Metrics = field(default_factory=Metrics)
    #: The act fallback's wait between check reads (a poll period, not a wait on a condition).
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep
    #: The cause commit's change reference (cdevents-sim's change events); None: not looked up.
    change_refs: ChangeRefs | None = None


@dataclass(frozen=True)
class Outcome:
    """`action` is what the bridge set out to do. `post_failed` says the forge refused
    the write, so `url` is None and nothing reached GitHub."""

    action: Action
    url: str | None = None
    level: Level | None = None
    post_failed: bool = False


# -- rendering ---------------------------------------------------------------

# An @ that starts a word (`@team`), not one inside an address: the PII scan must still see emails.
_MENTION = re.compile(r"(?<![\w.+-])@(?=[A-Za-z0-9_-])")
# Link, image, autolink and code syntax: escaped so model text renders as text.
_MARKDOWN = re.compile(r"([\[\]()!<>`\\])")
# `#123` and `owner/repo#123` would write a cross-reference into that issue.
_ISSUE_REF = re.compile(r"#(?=[A-Za-z0-9])")
# `GH-12` is GitHub's other issue-reference form.
_GH_REF = re.compile(r"\b(GH)-(?=\d)", re.IGNORECASE)
# GFM autolinks a bare `scheme://...` and `www....` without any Markdown syntax.
_SCHEME_SEP = re.compile(r"(?<=[A-Za-z0-9+.-]):(?=//)")
_WWW = re.compile(r"\b(www)\.", re.IGNORECASE)
# The template already labels the line "Timeline:"; the model often starts the field with it too.
# Also a bare label word, but only when content follows it ("Timeline change CHG-...",
# "Timeline CHG-...", "Timeline 8312067 ..."), never a phrase ("Timeline of events: ...")
# or a longer word ("Timelines").
_TIMELINE_PREFIX = re.compile(
    r"^\s*timeline(?:\s*[:\-\u2013\u2014]\s*|\s+(?=change\b|CHG-|[0-9a-f]{7,40}\b))", re.IGNORECASE
)


def plain(value: object) -> str:
    """One line of model text for a public comment.

    Format characters are dropped (they can hide text from the PII scan), whitespace is
    collapsed (so it can't start a new Markdown block), link, image, autolink and code
    syntax is backslash-escaped (so it can't link, embed a tracking image or break out of
    the line), and @-mentions, issue references (`#12`, `GH-12`) and bare autolinks
    (`https://...`, `www....`) are broken with a zero-width space (so they notify no one,
    write nothing into another issue and put no clickable link in a public comment).
    """
    text = " ".join(pii.strip_format(str(value)).split())
    text = _MARKDOWN.sub(r"\\\1", text)
    text = _ISSUE_REF.sub("#\u200b", text)
    text = _GH_REF.sub("\\1\u200b-", text)
    text = _SCHEME_SEP.sub(":\u200b", text)
    text = _WWW.sub("\\1\u200b.", text)
    return _MENTION.sub("@\u200b", text)


def title_text(value: object) -> str:
    """One line for a PR title or commit subject. Titles aren't Markdown, so nothing is
    backslash-escaped, but mentions and issue references are broken as in `plain`."""
    text = " ".join(pii.strip_format(str(value)).split())
    text = _ISSUE_REF.sub("#\u200b", text)
    text = _GH_REF.sub("\\1\u200b-", text)
    return _MENTION.sub("@\u200b", text)


_SENTENCE_END = re.compile(r"(?<=[.!?])\s+(?=\S)")


def _cap(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    cut = text[: limit - 1]
    if " " in cut:
        cut = cut[: cut.rindex(" ")]
    return cut.rstrip(" ,;:-") + "…"


# The operator's change reference (scripts/common.sh new_change_ref). tests/e2e/rung1.sh
# greps the Timeline line for it, so capping must never drop it.
CHANGE_REF = re.compile(r"\bCHG-[A-Z2-7]{6}\b")
KEPT_REFS_MAX = 1  # without the cause's ref: only the first in the text, never a later one


def short_text(value: object, limit: int, keep: re.Pattern[str] | None = None,
               must_keep: Sequence[str] = ()) -> str:
    """The first sentence of `value`, cut on a word boundary with an ellipsis if it is still
    longer than `limit` characters. Applied before `plain`, which only adds escapes.

    Tokens matching `keep` anywhere in `value` (at most KEPT_REFS_MAX), or the strings in
    `must_keep` when given, that the result would lack are appended in parentheses, and the
    text is cut shorter to make room, so the result stays within `limit`.
    """
    text = " ".join(str(value).split())
    first = _SENTENCE_END.split(text, maxsplit=1)[0]
    if must_keep:
        kept = list(dict.fromkeys(must_keep))
    else:
        kept = list(dict.fromkeys(keep.findall(text)))[:KEPT_REFS_MAX] if keep else []
    missing: list[str] = []
    while True:  # each pass can only add to `missing`, so this ends
        suffix = f" ({', '.join(missing)})" if missing else ""
        prefix = _cap(first, limit - len(suffix))
        now = [ref for ref in kept if ref not in prefix]
        if now == missing:
            return prefix + suffix
        missing = now


# A change reference with its own brackets, and the separator before it, so dropping one
# leaves no "()" or ", ," behind.
_REF_WITH_DECOR = re.compile(r"(?:\s*,)?\s*([(\[])?\s*\bCHG-[A-Z2-7]{6}\b\s*(?(1)[)\]])")


def _drop_refs_except(text: str, keep_ref: str) -> str:
    def drop(m: re.Match[str]) -> str:
        return m.group(0) if keep_ref in m.group(0) else ""

    out = _REF_WITH_DECOR.sub(drop, text)
    out = re.sub(r"\s+([,.;:!?)\]])", r"\1", out)
    out = re.sub(r"([(\[])\s+", r"\1", out)
    return " ".join(out.split())


def timeline_text(delivery_context: str, cause_ref: str | None = None) -> str:
    """The Timeline bullet's text: no doubled label, capped, and the change reference kept.

    With `cause_ref` (the cause commit's own reference, from the timeline), every other
    reference is dropped and that one is appended if the text lacks it, so the line never
    names another change's ticket. Without it, the first reference in the text is kept.
    """
    text = timeline_line(delivery_context)
    if cause_ref:
        return short_text(_drop_refs_except(text, cause_ref), ITEM_MAX, must_keep=(cause_ref,))
    return short_text(text, ITEM_MAX, keep=CHANGE_REF)


def timeline_line(delivery_context: str) -> str:
    """The delivery context without a leading "Timeline:" the template already prints."""
    text = delivery_context
    for _ in range(2):  # "Timeline: Timeline change ..." carries the label twice
        text = _TIMELINE_PREFIX.sub("", text, count=1)
    return text


_env = Environment(
    loader=PackageLoader("bridge", "templates"),
    autoescape=False,  # Markdown, not HTML
    undefined=StrictUndefined,
    keep_trailing_newline=True,
    trim_blocks=False,
)
_env.filters["plain"] = plain


def render(template: str, **context: object) -> str:
    return _env.get_template(template).render(**context)


def argo_url(settings: Settings, hook: ArgoDegradedHook) -> str:
    return f"{settings.argo_ui_url.rstrip('/')}/applications/argocd/{hook.app}"


def code(value: object) -> str:
    """One value as an inline code span: no backticks, no line breaks, no format characters."""
    text = " ".join(pii.strip_format(str(value)).replace("`", "'").split())
    return f"`{text}`"


@functools.cache
def pr_sections() -> dict[str, Any]:
    """The fix-PR body's headings and fixed sentences: proposals, kept in one file."""
    return yaml.safe_load(resources.files("bridge").joinpath("templates/pr_sections.yaml").read_text())


def _version(tag: str) -> tuple[int, ...] | None:
    m = re.fullmatch(r"v?(\d+(?:\.\d+)*)", tag.strip())
    return tuple(int(p) for p in m.group(1).split(".")) if m else None


def _blast_radius(fix: FixChange, rca: RCA, annotation: str, image_tag: str | None, cve_tag: str | None,
                  kustomization: str) -> tuple[str, str]:
    br = pr_sections()["blast_radius"]
    patch = rca.proposed_patch
    changes = br["changes"].format(
        key=code(patch.key), file=code(patch.file), annotation=code(annotation),
        cv_from=fix.config_version_from, cv_to=fix.config_version_to,
    )
    if not image_tag:
        return changes, br["leaves"]
    image, cve = _version(image_tag), _version(cve_tag or "")
    note = br["security_note"].format(cve_tag=cve_tag) if image and cve and image >= cve else ""
    leaves = br["leaves_image"].format(image=code(image_tag), kustomization=code(kustomization), security_note=note)
    return changes, leaves


def _revisions(history: Sequence[HistoryEntry], cause: str, synced: str | None) -> list[dict[str, str]]:
    rows = []
    for entry in sorted(history, key=lambda h: h.id)[-REVISIONS_SHOWN:]:
        notes = [n for n, sha in (("cause", cause), ("synced", synced)) if sha and entry.revision == sha]
        rows.append({
            "id": str(entry.id),
            "short": entry.revision[:SHORT_REVISION],
            "deployed": entry.deployedAt.astimezone(UTC).strftime("%Y-%m-%d %H:%M"),
            "note": ", ".join(notes),
        })
    return rows


def render_fix_pr_body(
    rca: RCA,
    fix: FixChange,
    *,
    level: Level,
    cause_title: str | None = None,
    argo_url: str = "",
    history: Sequence[HistoryEntry] = (),
    synced_revision: str | None = None,
    annotation: str = "example.dev/config-version",
    image_tag: str | None = None,
    cve_tag: str | None = None,
    kustomization: str = "kustomization.yaml",
    cause_ref: str | None = None,
) -> str:
    """The fix PR's body: root cause and the `Cause:` line, at most three evidence bullets
    (the last one the delivery context), the blast radius, and the Argo record for the
    reviewer, collapsed. `rca` is the guardrail-normalized answer (full cause SHA)."""
    changes, leaves = _blast_radius(fix, rca, annotation, image_tag, cve_tag, kustomization)
    return render(
        "fix_pr_body.md.j2",
        s=pr_sections(),
        rca=rca,
        root_cause=short_text(rca.root_cause, ROOT_CAUSE_MAX),
        cause_title=cause_title,
        evidence=[short_text(e, ITEM_MAX) for e in rca.evidence[:EVIDENCE_BULLETS]],
        timeline=timeline_text(rca.delivery_context, cause_ref),
        blast_changes=changes,
        blast_leaves=leaves,
        argo_url=argo_url,
        revisions=_revisions(history, rca.cause_commit_sha, synced_revision),
        level=level,
    )


def fix_branch(app: str, cause: str, revision: str) -> str:
    return f"agent/{app}-{cause[:SHORT_REVISION]}-{revision[:SHORT_REVISION]}"


# `agent/<app>-<cause7>-<revision7>`; the app name may itself contain hyphens.
_FIX_BRANCH = re.compile(r"^agent/(?P<app>.+)-(?P<cause>[0-9a-f]{7})-(?P<revision>[0-9a-f]{7})$")


def _image_tag(kustomization_text: str, app: str) -> str | None:
    """The app's `newTag` from a kustomization's `images:`; None when it can't be read."""
    try:
        doc = yaml.safe_load(kustomization_text)
    except yaml.YAMLError:
        return None
    images = doc.get("images") if isinstance(doc, dict) else None
    if not isinstance(images, list):
        return None
    tags = [i.get("newTag") for i in images if isinstance(i, dict) and i.get("name") == app]
    return str(tags[0]) if len(tags) == 1 and tags[0] is not None else None


# -- the pipeline ------------------------------------------------------------


class _Run:
    def __init__(self, hook: ArgoDegradedHook, deps: Deps, level: Level) -> None:
        self.hook = hook
        self.deps = deps
        self.level = level
        self.s = deps.settings
        self.post_failed = False

    def stage(self, step: str, detail: str) -> None:
        stagelog.emit(step, detail, self.s.stage_cols)

    async def emit(self, event: dict) -> None:
        try:
            await self.deps.emitter.emit(event)
        except Exception:  # a lost event never fails an incident
            log.warning("emitter failed for %s", event.get("context", {}).get("type"), exc_info=True)

    def action_event(self, action: str, url: str | None, reason: str | None = None) -> dict:
        return events.agent_action(
            action, url, reason, source=self.s.bridge_event_source, app=self.hook.app,
            level=self.level, revision=self.hook.revision, now=self.deps.clock(),
        )

    async def post(self, write: Awaitable[str]) -> str | None:
        """Run one forge write. A ForgeError is recorded, not raised, so the incident still
        gets its outcome, event and metric; the caller gets None for the URL."""
        try:
            return await write
        except ForgeError as exc:
            # ForgeError messages carry a method, a path and a status code, never a token.
            log.warning("incident %s: forge write failed: %s", self.hook.key, exc)
            self.stage("forge", "post failed")
            self.post_failed = True
            return None

    async def record(self, action: Action, url: str | None, reason: str | None, *extra: dict) -> None:
        """Count one action and emit its event, after `extra` events."""
        if self.post_failed:
            # Nothing reached GitHub: count and report the failure, naming what was intended.
            self.deps.metrics.action("post_failed")
            event = self.action_event("post_failed", None, action)
        else:
            self.deps.metrics.action(action)
            event = self.action_event(action, url, reason)
        for e in (*extra, event):
            await self.emit(e)

    async def finish(self, action: Action, url: str | None, reason: str | None, *extra: dict) -> Outcome:
        await self.record(action, url, reason, *extra)
        log.info("incident %s: %s (%s)%s", self.hook.key, action, url, " post failed" if self.post_failed else "")
        return Outcome(action, url, self.level, post_failed=self.post_failed)

    async def handoff(self, text: str, reason: str) -> Outcome:
        url = await self.post(self.deps.forge.comment_on_commit(self.hook.sync_revision, text))
        return await self.finish("holmes_failed", url, reason)

    async def investigate(self) -> HolmesResult | Outcome:
        received = self.hook.received_at or self.deps.clock()
        prompt = build_prompt(
            self.hook, live_window(received), config_version_annotation=self.s.config_version_annotation
        )
        self.stage("holmes", "investigating")
        try:
            result = await self.deps.holmes.investigate(prompt)
        except HolmesTimeout:
            self.stage("holmes", "timed out")
            return await self.handoff(TIMEOUT_HANDOFF.format(timeout=self.s.holmes_timeout_s), "timeout")
        except HolmesError as exc:
            log.warning("incident %s: holmes failed: %s", self.hook.key, exc)
            self.stage("holmes", "no usable answer")
            return await self.handoff(BAD_OUTPUT_HANDOFF, "bad_output")
        # O14: several calls per investigation, some of them failing, are normal.
        for call in result.tool_calls:
            self.stage("holmes", call)
        return result

    async def cause_title(self, sha: str) -> str | None:
        try:
            return await self.deps.forge.commit_title(sha)
        except ForgeError:
            return None

    async def cause_ref(self, sha: str) -> str | None:
        """The cause commit's change reference from the timeline, or None (never raises)."""
        lookup = self.deps.change_refs
        if lookup is None:
            return None
        try:
            ref = await lookup.change_ref(self.hook.app, sha)
        except Exception:  # noqa: BLE001  a missing reference must not fail an incident
            log.warning("change_ref lookup failed for %s", sha[:SHORT_REVISION])
            return None
        return ref if ref and CHANGE_REF.fullmatch(ref) else None

    async def suggest_target(self, sha: str) -> tuple[str, int | None]:
        try:
            prs = await self.deps.forge.prs_for_commit(sha)
        except ForgeError:
            prs = []
        return sha, (prs[0] if prs else None)

    async def pii_gate(self, body: str, rca_event: dict, *extra: str) -> Outcome | None:
        """Scan everything that would leave the bridge; on a hit, post a fixed notice instead."""
        texts = (body, json.dumps(rca_event["customData"], ensure_ascii=False), *extra)
        payloads = tuple(pii.normalize(t) for t in texts)
        found = {(h.kind, text[h.span[0]:h.span[1]]) for text in payloads for h in pii.scan(text)}
        if not found:
            self.stage("pii", "clean")
            return None
        kinds = sorted({kind for kind, _ in found})
        for kind, _ in sorted(found):
            self.deps.metrics.pii_caught(kind)
        log.warning("incident %s: PII gate blocked the post (%s)", self.hook.key, ", ".join(kinds))
        self.stage("pii", "blocked")
        blocked = render("pii_blocked_comment.md.j2", kinds=kinds, argo_url=argo_url(self.s, self.hook),
                         level=self.level)
        url = await self.post(self.deps.forge.comment_on_commit(self.hook.sync_revision, blocked))
        return await self.finish("pii_blocked", url, ",".join(kinds))

    async def check(self, raw: RCA) -> tuple[RCA, list[Refusal]]:
        rca, refusals = await guardrails.evaluate(raw, self.hook, self.deps.forge, self.s)
        self.count_refusals(refusals)
        if not refusals:
            self.stage("guardrails", "passed")
        return rca, refusals

    def count_refusals(self, refusals: list[Refusal]) -> None:
        for refusal in refusals:
            self.deps.metrics.guardrail(refusal.reason)
            self.stage("refused", refusal.reason)

    def rca_event(self, rca: RCA) -> dict:
        return events.rca_completed(self.hook, rca, self.level, source=self.s.bridge_event_source, now=self.deps.clock())

    async def refuse(self, rca: RCA, refusals: list[Refusal], rca_event: dict) -> Outcome:
        """Post the refusal: on the cause once it checked out, otherwise on the synced
        revision, so a wrong answer never lands on an innocent commit."""
        body = render("refusal_comment.md.j2", refusals=refusals, argo_url=argo_url(self.s, self.hook),
                      level=self.level, sentence=pr_sections()["refusal"][self.level])
        blocked = await self.pii_gate(body, rca_event)
        if blocked:
            return blocked
        unverified = any(r.reason == "cause_not_in_history" for r in refusals)
        target = self.hook.sync_revision if unverified else rca.cause_commit_sha
        url = await self.post(self.deps.forge.comment_on_commit(target, body))
        if url:
            self.stage(self.level, "refusal posted")
        reason = ",".join(dict.fromkeys(r.reason for r in refusals))
        return await self.finish("refused", url, reason, rca_event)

    async def suggest(self) -> Outcome:
        result = await self.investigate()
        if isinstance(result, Outcome):
            return result

        rca, refusals = await self.check(result.rca)
        rca_event = self.rca_event(rca)
        if refusals:
            return await self.refuse(rca, refusals, rca_event)

        body = render(
            "rca_comment.md.j2",
            rca=rca,
            root_cause=short_text(rca.root_cause, ROOT_CAUSE_MAX),
            timeline=timeline_text(rca.delivery_context, await self.cause_ref(rca.cause_commit_sha)),
            evidence=[short_text(e, ITEM_MAX) for e in rca.evidence[:EVIDENCE_BULLETS]],
            patch=rca.proposed_patch,
            cause_title=await self.cause_title(rca.cause_commit_sha),
            argo_url=argo_url(self.s, self.hook),
            level=self.level,
        )
        blocked = await self.pii_gate(body, rca_event)
        if blocked:
            return blocked

        forge = self.deps.forge
        sha, pr = await self.suggest_target(rca.cause_commit_sha)
        if pr is not None:
            url = await self.post(forge.comment_on_pr(pr, body))
            if url:
                self.stage("suggest", "commented on PR")
        else:
            url = await self.post(forge.comment_on_commit(sha, body))
            if url:
                self.stage("suggest", "commented")
        return await self.finish("commented", url, None, rca_event)


    # -- propose (Task 4.3) ----------------------------------------------------

    async def open_pr_guard(self) -> Outcome | None:
        """One open fix PR per app (Review Focus 5), checked before any LLM spend.

        A replay of the PR's own revision posts nothing; another degraded revision gets
        one pointer comment on the open PR. A failed lookup is logged and the incident
        goes on: the branch name still stops a second PR for the same revision.
        """
        try:
            open_prs = await self.deps.forge.list_open_agent_prs(self.hook.app)
        except ForgeError as exc:
            log.warning("incident %s: open agent PRs unknown: %s", self.hook.key, exc)
            return None
        if not open_prs:
            return None
        pr = open_prs[0]
        self.stage(self.level, "pr already open")
        if pr.branch.endswith(f"-{self.hook.revision[:SHORT_REVISION]}"):
            return await self.finish("duplicate", pr.url, "same_revision")
        text = ANOTHER_REVISION.format(revision=self.hook.revision)
        url = await self.post(self.deps.forge.comment_on_pr(pr.number, text))
        return await self.finish("duplicate", url, "open_pr")

    async def build(self, rca: RCA) -> tuple[FixChange, str] | Refusal:
        """The two-line fix and the tracked-branch SHA it was read at; a failure is a
        `patch_failed` refusal. Both files are read at one SHA, which becomes the fix
        commit's parent, so a push that lands meanwhile is merged by the PR, not reverted."""
        forge = self.deps.forge
        try:
            ref = await forge.branch_head(self.s.tracked_branch)
            config_text = await forge.read_file(rca.proposed_patch.file, ref)
            rollout_text = await forge.read_file(self.s.rollout_file, ref)
        except ForgeError:
            return Refusal("patch_failed", "could not read the files to change")
        try:
            fix = build_fix(rca, config_text, rollout_text, self.s.config_version_annotation,
                            rollout_path=self.s.rollout_file)
        except PatchError as exc:
            return Refusal("patch_failed", str(exc))
        return fix, ref

    async def image_tag(self, ref: str) -> str | None:
        try:
            text = await self.deps.forge.read_file(self.s.kustomization_file, ref)
        except ForgeError:
            return None
        return _image_tag(text, self.hook.app)

    async def propose(self) -> Outcome:
        opened = await self.open_fix_pr()
        if isinstance(opened, Outcome):
            return opened
        pr, rca_event, created = opened
        return await self.finish("pr_opened", pr.url, None, rca_event, created)

    async def open_fix_pr(self) -> Outcome | tuple[PullRequest, dict, dict]:
        """The propose steps up to an open fix PR. Returns the PR with its `rca.completed` and
        `change.created` events (not yet emitted), or the incident's final Outcome."""
        guarded = await self.open_pr_guard()
        if guarded:
            return guarded
        result = await self.investigate()
        if isinstance(result, Outcome):
            return result

        rca, refusals = await self.check(result.rca)
        rca_event = self.rca_event(rca)
        if refusals:
            return await self.refuse(rca, refusals, rca_event)
        built = await self.build(rca)
        if isinstance(built, Refusal):
            self.count_refusals([built])
            return await self.refuse(rca, [built], rca_event)
        fix, base_sha = built

        patch = rca.proposed_patch
        title = title_text(f"fix({self.hook.app}): restore {patch.key} to {patch.to_value} and roll config")
        summary = [title_text(line) for line in fix.diff_summary]
        commit_message = "\n".join([title, "", *summary, "", f"Cause: {rca.cause_commit_sha}"])
        body = render_fix_pr_body(
            rca, fix, level=self.level,
            cause_title=await self.cause_title(rca.cause_commit_sha),
            argo_url=argo_url(self.s, self.hook),
            history=self.hook.history,
            synced_revision=self.hook.sync_revision,
            annotation=self.s.config_version_annotation,
            image_tag=await self.image_tag(base_sha),
            cve_tag=self.s.cve_fix_tag or None,
            kustomization=self.s.kustomization_file,
            cause_ref=await self.cause_ref(rca.cause_commit_sha),
        )
        blocked = await self.pii_gate(body, rca_event, title, commit_message)
        if blocked:
            return blocked

        branch = fix_branch(self.hook.app, rca.cause_commit_sha, self.hook.revision)
        try:
            pr = await self.deps.forge.open_pr(
                base=self.s.tracked_branch, branch=branch, title=title, body=body,
                changes=fix.files, commit_message=commit_message, base_sha=base_sha,
            )
        except ForgeConflict:
            # The branch exists: this revision already has a fix branch (a replay).
            self.stage(self.level, "pr already open")
            return await self.finish("duplicate", None, "branch_exists", rca_event)
        except ForgeError as exc:
            log.warning("incident %s: forge write failed: %s", self.hook.key, exc)
            self.stage("forge", "post failed")
            self.post_failed = True
            return await self.finish("pr_opened", None, None, rca_event)
        self.stage(self.level, "pr opened")
        created = events.change_created(
            pr.url, branch, self.s.github_repo, source=self.s.bridge_event_source, app=self.hook.app,
            now=self.deps.clock(),
        )
        return pr, rca_event, created

    # -- act (Task 5.4) ----------------------------------------------------------

    async def act(self) -> Outcome:
        """Open the fix PR as at propose, then hand the merge to GitHub's auto-merge.

        Policy results are not counted here: on the usual path the check is still pending when
        auto-merge is enabled, so the reconciler counts them, and posts the one comment on a
        failure, for both paths alike.
        """
        opened = await self.open_fix_pr()
        if isinstance(opened, Outcome):
            return opened
        pr, rca_event, created = opened
        await self.record("pr_opened", pr.url, None, rca_event, created)
        forge = self.deps.forge
        method = await self.merge_method()
        try:
            result = await forge.enable_auto_merge(pr, method)
        except ForgeError as exc:
            # The PR stays open for a human; nothing merges it without the check.
            log.warning("incident %s: enabling auto-merge failed: %s", self.hook.key, exc)
            self.stage("forge", "auto-merge failed")
            self.post_failed = True
            return await self.finish("auto_merge_enabled", pr.url, None)
        if result == "enabled":
            self.stage("act", "auto-merge on")
            return await self.finish("auto_merge_enabled", pr.url, None)

        self.stage("act", "waiting on policy")
        status = await self.wait_for_check(pr)
        if status == "success":
            self.stage("act", "policy passed")
            return await self.merge(pr, method)
        if status == "failure":
            # Left open. The reconciler posts the comment and the policy_failed event, once.
            self.stage("act", "policy failed")
            log.info("incident %s: policy-check failed on %s; left for a human", self.hook.key, pr.url)
            return Outcome("policy_failed", pr.url, self.level)
        self.stage("act", "no policy result")
        minutes = round(self.s.act_check_timeout_s / 60)
        text = pr_sections()["policy"]["no_result"].format(minutes=minutes)
        url = await self.post(forge.comment_on_pr(pr.number, text))
        return await self.finish("policy_failed", url, f"check_{status}")

    async def merge_method(self) -> MergeMethod:
        """The repo's allowed method, preferring `merge`; `merge` when the settings can't be read."""
        try:
            allowed = await self.deps.forge.merge_methods()
        except ForgeError as exc:
            log.warning("incident %s: merge methods unknown: %s", self.hook.key, exc)
            return "merge"
        preferred: tuple[MergeMethod, ...] = ("merge", "squash", "rebase")
        return next((m for m in preferred if m in allowed), "merge")

    async def wait_for_check(self, pr: PullRequest) -> CheckStatus:
        """Read `policy-check` on the PR's head every `act_check_poll_s` until it concludes, for
        at most `act_check_timeout_s`. A failed read counts as pending: only a real success merges."""
        waited = 0.0
        while True:
            try:
                status = await self.deps.forge.check_run_status(pr.head_sha, self.s.policy_check_context)
            except ForgeError as exc:
                log.warning("incident %s: check read failed: %s", self.hook.key, exc)
                status = "pending"
            if status in ("success", "failure") or waited >= self.s.act_check_timeout_s:
                return status
            await self.deps.sleep(self.s.act_check_poll_s)
            waited += self.s.act_check_poll_s

    async def merge(self, pr: PullRequest, method: MergeMethod) -> Outcome:
        """The fallback's own merge, at the PR's head SHA. The PR is marked as announced first, so
        the reconciler counts the merge but leaves its `change.merged` to this flow."""
        registry = self.deps.registry
        registry.announce_merge(pr.number)
        try:
            sha = await self.deps.forge.merge_pr(pr, method)
        except ForgeError as exc:
            registry.forget_merge(pr.number)
            log.warning("incident %s: merge failed: %s", self.hook.key, exc)
            self.stage("forge", "merge failed")
            self.post_failed = True
            return await self.finish("merged", pr.url, None)
        self.stage("act", "merged")
        merged = events.change_merged(
            pr.url, sha, self.s.bot_login, source=self.s.bridge_event_source, repo=self.s.github_repo,
            app=self.hook.app, now=self.deps.clock(),
        )
        return await self.finish("merged", pr.url, None, merged)


_ACTORS: dict[str, Callable[[_Run], Awaitable[Outcome]]] = {
    "suggest": _Run.suggest, "propose": _Run.propose, "act": _Run.act,
}


async def handle_incident(hook: ArgoDegradedHook, deps: Deps) -> Outcome:
    deps.registry.mark(hook.key)
    autonomy, failsafe_reason = await read_autonomy(deps.forge, deps.settings.tracked_branch)
    level = autonomy.level
    stagelog.emit("autonomy", f"fail-safe {level}" if failsafe_reason else level, deps.settings.stage_cols)
    deps.metrics.incident(level)
    if failsafe_reason is None:
        deps.metrics.set_touchpoints(autonomy.touchpoints)

    return await _ACTORS[level](_Run(hook, deps, level))


async def rehydrate_registry(registry: IncidentRegistry, forge: Forge) -> int:
    """Mark every open fix PR's incident as seen, from its branch name (Review Focus 5).

    Run at startup, before the first webhook, so a replay after a restart does nothing.
    Returns how many incidents were marked; other `agent/*` branches are ignored.
    """
    keys = []
    for pr in await forge.list_open_agent_prs(None):
        m = _FIX_BRANCH.match(pr.branch)
        if m:
            keys.append(f"{m['app']}@{m['revision']}")
    registry.rehydrate(keys)
    return len(keys)


async def rehydrate_at_startup(registry: IncidentRegistry, forge: Forge) -> None:
    """`rehydrate_registry`, bounded in time; a failure is logged and startup goes on."""
    try:
        count = await asyncio.wait_for(rehydrate_registry(registry, forge), REHYDRATE_TIMEOUT_S)
    except Exception as exc:  # noqa: BLE001  any failure: start anyway, the branch name still guards
        log.warning("rehydrate from open agent PRs failed: %s", type(exc).__name__)
        return
    log.info("rehydrated %d open agent PR(s)", count)


def outcome_for_status(outcome: Outcome) -> dict[str, object]:
    return {
        "action": outcome.action,
        "url": outcome.url,
        "holmes_failed": outcome.action == "holmes_failed",
        "post_failed": outcome.post_failed,
    }


__all__ = [
    "Deps", "Outcome", "fix_branch", "handle_incident", "outcome_for_status", "plain", "rehydrate_at_startup",
    "rehydrate_registry", "render", "render_fix_pr_body", "short_text",
]
