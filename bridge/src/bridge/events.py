"""The bridge's own CDEvents: one per agent action, so every action is on the timeline (spec 7.1).

Every event carries `context.source = BRIDGE_EVENT_SOURCE`. cdevents-sim keeps those,
and every `dev.cdeventsx.*` event, off `GET /timeline`, so HolmesGPT never reads the
agent's own output (P16).
"""

from __future__ import annotations

import logging
import uuid
from datetime import UTC, datetime
from typing import Any, Protocol

import httpx

from .models import ArgoDegradedHook
from .rca import RCA

log = logging.getLogger("bridge.events")

SPEC_VERSION = "0.5.1"
RCA_COMPLETED = "dev.cdeventsx.holmesgpt-rca.completed.0.1.0"
AGENT_ACTION = "dev.cdeventsx.agent-action.0.1.0"
CHANGE_CREATED = "dev.cdevents.change.created.0.4.0"
CHANGE_MERGED = "dev.cdevents.change.merged.0.3.0"  # O1: v0.5.1 defines merged at 0.3.0


def _timestamp(now: datetime | None) -> str:
    return (now or datetime.now(UTC)).astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _event(etype: str, subject: dict[str, Any], custom: dict[str, Any], source: str, now: datetime | None) -> dict:
    return {
        "context": {
            "specversion": SPEC_VERSION,
            "id": str(uuid.uuid4()),
            "source": source,
            "type": etype,
            "timestamp": _timestamp(now),
        },
        "subject": subject,
        "customData": custom,
    }


def rca_completed(
    hook: ArgoDegradedHook, rca: RCA, level: str, *, source: str, now: datetime | None = None
) -> dict:
    """The RCA as the agent gave it. Carries model text, so it is PII-scanned before sending."""
    return _event(
        RCA_COMPLETED,
        {"id": hook.key, "source": source},
        {
            "root_cause": rca.root_cause,
            "cause_commit_sha": rca.cause_commit_sha,
            "confidence": rca.confidence,
            "level": level,
            "app": hook.app,
        },
        source,
        now,
    )


def agent_action(
    action: str,
    target_url: str | None,
    reason: str | None = None,
    *,
    source: str,
    app: str | None = None,
    level: str | None = None,
    revision: str | None = None,
    now: datetime | None = None,
) -> dict:
    """Any other bridge action. Never carries model text: `reason` is a fixed word or list of words."""
    custom: dict[str, Any] = {"action": action, "target_url": target_url, "reason": reason}
    if app:
        custom["app"] = app
    if level:
        custom["level"] = level
    if revision:
        custom["revision"] = revision
    subject_id = f"{app}@{revision}" if app and revision else (target_url or action)
    return _event(AGENT_ACTION, {"id": subject_id, "source": source}, custom, source, now)


def _repo_content(repo: str) -> dict[str, Any]:
    return {"repository": {"id": repo, "source": "https://github.com"}}


def change_created(
    pr_url: str, branch: str, repo: str, *, source: str, app: str | None = None, now: datetime | None = None
) -> dict:
    """The agent opened a fix PR (Task 4.3). `app` is how cdevents-sim files it (the PR URL
    in subject.id names no app)."""
    custom: dict[str, Any] = {"pr_url": pr_url, "branch": branch}
    if app:
        custom["app"] = app
    return _event(
        CHANGE_CREATED,
        {"id": pr_url, "source": source, "content": {"description": f"agent fix PR from {branch}", **_repo_content(repo)}},
        custom,
        source,
        now,
    )


def change_merged(
    pr_url: str,
    merge_sha: str,
    merged_by: str,
    *,
    source: str,
    repo: str | None = None,
    app: str | None = None,
    now: datetime | None = None,
) -> dict:
    """The agent's merge (or auto-merge) landed (Task 5.4)."""
    content = _repo_content(repo) if repo else {}
    custom: dict[str, Any] = {"pr_url": pr_url, "sha": merge_sha, "merged_by": merged_by}
    if app:
        custom["app"] = app
    return _event(
        CHANGE_MERGED,
        {"id": pr_url, "source": source, "content": content},
        custom,
        source,
        now,
    )


class Emitter(Protocol):
    async def emit(self, event: dict) -> None: ...


class NullEmitter:
    """Drops everything (the dry-run harness: no dry run may feed a later one, P16)."""

    async def emit(self, event: dict) -> None:
        return None


class CDEventsEmitter:
    """POSTs events to cdevents-sim. Never raises: a lost event must not fail an incident."""

    def __init__(self, url: str, *, http: httpx.AsyncClient | None = None, timeout_s: float = 5.0) -> None:
        self.url = url
        self._http = http or httpx.AsyncClient(timeout=timeout_s)

    async def emit(self, event: dict) -> None:
        etype = (event.get("context") or {}).get("type", "?")
        if not self.url:
            log.warning("event not delivered (%s): no CDEVENTS_URL", etype)
            return
        if not (event.get("context") or {}).get("source"):
            log.warning("event not delivered (%s): no BRIDGE_EVENT_SOURCE", etype)
            return
        try:
            r = await self._http.post(self.url, json=event)
        except Exception as exc:  # noqa: BLE001  never raise from here
            log.warning("event not delivered (%s): %s", etype, type(exc).__name__)
            return
        if r.status_code >= 400:
            log.warning("event not delivered (%s): HTTP %s", etype, r.status_code)
