"""One incident, start to finish: autonomy → HolmesGPT → guardrails → render → PII gate → act → events.

Slice 3 implements `suggest`: comment the RCA on the cause's PR, or on the cause
commit. `propose` and `act` arrive in Tasks 4.3 and 5.4; until then the level
dispatch raises `NotImplementedError` before any LLM call is made.

Model text leaves the bridge in two places: the comment and the `rca_completed`
event. Both are PII-scanned before anything is sent, and a hit blocks both (spec
7.1). Nothing posted on a refusal, a block or a HolmesGPT failure is model text
except the refusal's details, which are scanned the same way.
"""

from __future__ import annotations

import json
import logging
import re
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Literal, Protocol

from jinja2 import Environment, PackageLoader, StrictUndefined

from . import events, guardrails, pii, stagelog
from .autonomy import Level, read_autonomy
from .config import Settings
from .events import Emitter
from .forge import Forge, ForgeError
from .holmes import HolmesError, HolmesResult, HolmesTimeout
from .incidents import IncidentRegistry
from .metrics import Metrics
from .models import ArgoDegradedHook
from .prompt import build_prompt, live_window

log = logging.getLogger("bridge.pipeline")

Action = Literal[
    "commented", "refused", "pii_blocked", "holmes_failed", "pr_opened", "auto_merge_enabled", "merged",
    "policy_failed", "duplicate",
]
EVIDENCE_BULLETS = 2  # plus the Timeline bullet: at most three on the projector
TIMEOUT_HANDOFF = "Investigation did not finish in {timeout:g} s; a human should take this one."
BAD_OUTPUT_HANDOFF = "Investigation did not return a usable answer; a human should take this one."


class Holmes(Protocol):
    async def investigate(self, prompt: str) -> HolmesResult: ...


def _utcnow() -> datetime:
    return datetime.now(UTC)


@dataclass
class Deps:
    forge: Forge
    holmes: Holmes
    emitter: Emitter
    settings: Settings
    registry: IncidentRegistry
    clock: Callable[[], datetime] = _utcnow
    metrics: Metrics = field(default_factory=Metrics)


@dataclass(frozen=True)
class Outcome:
    action: Action
    url: str | None = None
    level: Level | None = None


# -- rendering ---------------------------------------------------------------

# An @ that starts a word (`@team`), not one inside an address: the PII scan must still see emails.
_MENTION = re.compile(r"(?<![\w.+-])@(?=[A-Za-z0-9_-])")


def plain(value: object) -> str:
    """One line of model text for a comment: whitespace collapsed (so it can't start a
    new Markdown block) and @-mentions broken (so it can't notify anyone)."""
    return _MENTION.sub("@\u200b", " ".join(str(value).split()))


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


# -- the pipeline ------------------------------------------------------------


class _Run:
    def __init__(self, hook: ArgoDegradedHook, deps: Deps, level: Level) -> None:
        self.hook = hook
        self.deps = deps
        self.level = level
        self.s = deps.settings

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

    async def finish(self, action: Action, url: str | None, reason: str | None, *extra: dict) -> Outcome:
        self.deps.metrics.action(action)
        for event in (*extra, self.action_event(action, url, reason)):
            await self.emit(event)
        log.info("incident %s: %s (%s)", self.hook.key, action, url)
        return Outcome(action, url, self.level)

    async def handoff(self, text: str, reason: str) -> Outcome:
        url = await self.deps.forge.comment_on_commit(self.hook.sync_revision, text)
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

    async def suggest_target(self, sha: str) -> tuple[str, int | None]:
        try:
            prs = await self.deps.forge.prs_for_commit(sha)
        except ForgeError:
            prs = []
        return sha, (prs[0] if prs else None)

    async def pii_gate(self, body: str, rca_event: dict) -> Outcome | None:
        payloads = (body, json.dumps(rca_event["customData"], ensure_ascii=False))
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
        url = await self.deps.forge.comment_on_commit(self.hook.sync_revision, blocked)
        return await self.finish("pii_blocked", url, ",".join(kinds))

    async def suggest(self) -> Outcome:
        result = await self.investigate()
        if isinstance(result, Outcome):
            return result

        rca, refusals = await guardrails.evaluate(result.rca, self.hook, self.deps.forge, self.s)
        for refusal in refusals:
            self.deps.metrics.guardrail(refusal.reason)
            self.stage("refused", refusal.reason)
        if not refusals:
            self.stage("guardrails", "passed")

        common = {"argo_url": argo_url(self.s, self.hook), "level": self.level}
        if refusals:
            body = render("refusal_comment.md.j2", refusals=refusals, **common)
        else:
            body = render(
                "rca_comment.md.j2",
                rca=rca,
                evidence=rca.evidence[:EVIDENCE_BULLETS],
                patch=rca.proposed_patch,
                cause_title=await self.cause_title(rca.cause_commit_sha),
                **common,
            )
        rca_event = events.rca_completed(
            self.hook, rca, self.level, source=self.s.bridge_event_source, now=self.deps.clock()
        )
        blocked = await self.pii_gate(body, rca_event)
        if blocked:
            return blocked

        forge = self.deps.forge
        if refusals:
            # Post on the cause only once it checked out; otherwise on the synced revision,
            # so a wrong answer never lands on an innocent commit.
            unverified = any(r.reason == "cause_not_in_history" for r in refusals)
            target = self.hook.sync_revision if unverified else rca.cause_commit_sha
            url = await forge.comment_on_commit(target, body)
            self.stage("suggest", "refusal posted")
            reason = ",".join(dict.fromkeys(r.reason for r in refusals))
            return await self.finish("refused", url, reason, rca_event)

        sha, pr = await self.suggest_target(rca.cause_commit_sha)
        if pr is not None:
            url = await forge.comment_on_pr(pr, body)
            self.stage("suggest", "commented on PR")
        else:
            url = await forge.comment_on_commit(sha, body)
            self.stage("suggest", "commented")
        return await self.finish("commented", url, None, rca_event)


_ACTORS: dict[str, Callable[[_Run], Awaitable[Outcome]]] = {"suggest": _Run.suggest}


async def handle_incident(hook: ArgoDegradedHook, deps: Deps) -> Outcome:
    deps.registry.mark(hook.key)
    autonomy, failsafe_reason = await read_autonomy(deps.forge, deps.settings.tracked_branch)
    level = autonomy.level
    stagelog.emit("autonomy", f"fail-safe {level}" if failsafe_reason else level, deps.settings.stage_cols)
    deps.metrics.incident(level)
    if failsafe_reason is None:
        deps.metrics.set_touchpoints(autonomy.touchpoints)

    actor = _ACTORS.get(level)
    if actor is None:
        # Before any LLM call: propose (Task 4.3) and act (Task 5.4) are not built yet.
        raise NotImplementedError(f"autonomy level {level!r} is not implemented yet")
    return await actor(_Run(hook, deps, level))


def outcome_for_status(outcome: Outcome) -> dict[str, object]:
    return {"action": outcome.action, "url": outcome.url, "holmes_failed": outcome.action == "holmes_failed"}


__all__ = ["Deps", "Outcome", "handle_incident", "outcome_for_status", "plain", "render"]
