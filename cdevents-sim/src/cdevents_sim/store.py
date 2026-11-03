"""JSONL-backed event store with incident tracking."""

from __future__ import annotations

import json
import logging
import os
import re
import threading
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from .validate import CUSTOM_PREFIX, parse_timestamp

_REL_RE = re.compile(r"^-(\d+)([smhd])$")
_UNITS = {"s": "seconds", "m": "minutes", "h": "hours", "d": "days"}
_SHA_RE = re.compile(r"^[0-9a-fA-F]{7,40}$")
_FULL_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
_WORD_RE = re.compile(r"^[a-z][a-z0-9_.-]{0,31}$")
_LEVELS = {"suggest", "propose", "act"}
_APP_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")

log = logging.getLogger("cdevents_sim.store")

_TYPE_RE = re.compile(r"^dev\.cdevents(?:x)?\.(.+?)(?:\.\d+\.\d+\.\d+)?$")


def parse_since(value: str | None, now: datetime) -> datetime | None:
    """Parse an RFC 3339 timestamp or a relative offset such as -72h, -30m, -2d."""
    if value is None or value == "":
        return None
    m = _REL_RE.match(value)
    if m:
        return now - timedelta(**{_UNITS[m.group(2)]: int(m.group(1))})
    try:
        return parse_timestamp(value)
    except ValueError as exc:
        raise ValueError(f"since must be RFC 3339 or like -72h: {value!r}") from exc


def short_type(full: str) -> str:
    """dev.cdevents.incident.detected.0.3.0 -> incident.detected."""
    m = _TYPE_RE.match(full)
    return m.group(1) if m else full


def _iso(ts: datetime) -> str:
    return ts.strftime("%Y-%m-%dT%H:%M:%SZ")


def _get(d: Any, *path: str) -> Any:
    for p in path:
        if not isinstance(d, dict):
            return None
        d = d.get(p)
    return d


def _str(v: Any) -> str | None:
    return v if isinstance(v, str) and v else None


def extract_app(event: dict) -> str | None:
    cd = event.get("customData")
    subj = event.get("subject") or {}
    cand = _str(_get(cd, "app")) or _str(_get(cd, "argocd", "application"))
    if cand:
        return cand
    svc = _str(_get(subj, "content", "service", "id"))
    if svc:
        return svc.rsplit("/", 1)[-1]
    art = _str(_get(subj, "content", "artifactId"))
    if art and art.startswith("pkg:generic/"):
        return art[len("pkg:generic/"):].split("@", 1)[0].split("?", 1)[0] or None
    sid = _str(subj.get("id"))
    if sid and "/" in sid:
        return sid.split("/")[1] or None
    return _app_from_changed_files(_get(cd, "changed_files"))


def _app_from_changed_files(files: Any) -> str | None:
    """An operator change event (Task 3.14) names no app, only its changed files.
    `apps/<app>/...` paths that all agree give the app; anything else gives None."""
    if not isinstance(files, list) or not files:
        return None
    apps = set()
    for f in files:
        if not isinstance(f, str):
            return None
        path = f.strip()
        while path.startswith(("./", "/")):
            path = path[2:] if path.startswith("./") else path[1:]
        parts = path.split("/")
        if len(parts) < 3 or parts[0] != "apps" or not _APP_RE.match(parts[1]) or ".." in parts:
            return None
        apps.add(parts[1])
    return apps.pop() if len(apps) == 1 else None


def extract_revision(event: dict) -> str | None:
    cd = event.get("customData")
    subj = event.get("subject") or {}
    for cand in (_get(cd, "revision"), _get(cd, "cause_commit_sha"), _get(cd, "sha"), _get(cd, "argocd", "revision")):
        if _str(cand):
            return cand
    art = _str(_get(subj, "content", "artifactId"))
    if art and "@" in art:
        return art.split("@", 1)[1].split("?", 1)[0] or None
    sid = _str(subj.get("id"))
    if sid and "/incident/" in sid:
        return sid.split("/incident/", 1)[1] or None
    # A change event from a forge or the operator scripts (Δ28) names its commit only in
    # subject.id. Accept a full SHA there and nothing else.
    ctx = event.get("context") or {}
    if sid and short_type(str(ctx.get("type", ""))).startswith("change.") and _FULL_SHA_RE.match(sid):
        return sid
    return None


def short_commit(revision: str | None) -> str:
    """The 7-character commit for a panel column, or "" when the revision is not a SHA."""
    if isinstance(revision, str) and _SHA_RE.match(revision):
        return revision[:7].lower()
    return ""


@dataclass
class AddResult:
    status: str  # accepted | duplicate | dropped
    id: str | None = None
    reason: str | None = None


class Store:
    def __init__(self, path: Path, bridge_source: str | None = None):
        # P16 fails closed: without the bridge's CloudEvents source, /timeline
        # would let the bridge's standard-type events through to HolmesGPT.
        if not bridge_source or not bridge_source.strip():
            raise ValueError("BRIDGE_EVENT_SOURCE must be set (the bridge's CloudEvents source)")
        self.path = Path(path)
        self.bridge_source = bridge_source.strip()
        self._lock = threading.RLock()
        self._events: list[dict] = []  # raw CDEvents, insertion order
        self._ids: set[str] = set()
        self._incidents: list[dict] = []
        self._levels: dict[int, str] = {}
        self._load()

    # -- persistence ---------------------------------------------------
    def _load(self) -> None:
        if not self.path.exists():
            return
        data = self.path.read_bytes()
        lines = data.split(b"\n")
        offset = 0
        for i, raw in enumerate(lines):
            if raw.strip():
                try:
                    event = json.loads(raw)
                except ValueError:
                    if i < len(lines) - 1:
                        raise  # corruption before the tail is not recoverable
                    # A pod killed mid-append leaves a partial last line. Drop it
                    # so the next append starts on a clean line.
                    log.warning("dropping a partial last line in %s (%d bytes)", self.path, len(raw))
                    with self.path.open("r+b") as f:
                        f.truncate(offset)
                    return
                self._apply(event)
            offset += len(raw) + 1

    def _persist(self, event: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a") as f:
            f.write(json.dumps(event, separators=(",", ":")) + "\n")

    # -- classification ------------------------------------------------
    def is_agent_event(self, event: dict) -> bool:
        ctx = event["context"]
        if ctx["type"].startswith(CUSTOM_PREFIX):
            return True
        return ctx.get("source") == self.bridge_source

    # -- incident bookkeeping -------------------------------------------
    def _open_incident(self, app: str | None) -> dict | None:
        for inc in reversed(self._incidents):
            if inc["app"] == app and inc["resolved_at"] is None:
                return inc
        return None

    def _can_apply(self, event: dict) -> str | None:
        """Return a drop reason, or None."""
        if short_type(event["context"]["type"]) == "incident.resolved":
            if self._open_incident(extract_app(event)) is None:
                return "no open incident"
        return None

    def _apply(self, event: dict) -> None:
        ctx = event["context"]
        self._events.append(event)
        self._ids.add(ctx["id"])
        kind = short_type(ctx["type"])
        app = extract_app(event)
        ts = _iso(parse_timestamp(ctx["timestamp"]))
        if kind == "incident.detected":
            self._incidents.append({
                "subject_id": (event.get("subject") or {}).get("id"),
                "app": app,
                "revision": extract_revision(event),
                "detected_at": ts,
                "resolved_at": None,
                "level": None,
            })
        elif kind == "incident.resolved":
            inc = self._open_incident(app)
            if inc is not None:
                inc["resolved_at"] = ts
        level = _get(event, "customData", "level")
        if self.is_agent_event(event) and level in _LEVELS and app:
            for inc in reversed(self._incidents):
                if inc["app"] == app:
                    if inc["level"] is None:
                        inc["level"] = level
                    break

    def reset(self, drop_ids: set[str], keep_live_after: datetime | None) -> int:
        """Drop the seed events (`drop_ids`) and every other event older than
        `keep_live_after` (None drops all of them), then rebuild the incident state
        and rewrite the file. Returns how many events were dropped."""
        with self._lock:
            kept = []
            for ev in self._events:
                ctx = ev["context"]
                if ctx["id"] in drop_ids:
                    continue
                if keep_live_after is None or parse_timestamp(ctx["timestamp"]) < keep_live_after:
                    continue
                kept.append(ev)
            dropped = len(self._events) - len(kept)
            self._events, self._ids, self._incidents = [], set(), []
            for ev in kept:
                self._apply(ev)
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_name(self.path.name + ".tmp")
            tmp.write_text("".join(json.dumps(e, separators=(",", ":")) + "\n" for e in kept))
            os.replace(tmp, self.path)
            return dropped

    # -- public API ------------------------------------------------------
    def add(self, event: dict) -> AddResult:
        cid = event["context"]["id"]
        with self._lock:
            if cid in self._ids:
                return AddResult("duplicate", cid)
            reason = self._can_apply(event)
            if reason:
                return AddResult("dropped", cid, reason)
            self._apply(event)
            self._persist(event)
            return AddResult("accepted", cid)

    def _summary(self, event: dict) -> str:
        """Short text for panels. Bridge and custom events use fixed fields
        only, so model text never reaches a projector panel (spec 7.1)."""
        ctx = event["context"]
        kind = short_type(ctx["type"])
        cd = event.get("customData") if isinstance(event.get("customData"), dict) else {}
        if self.is_agent_event(event):
            parts = [kind]
            level = cd.get("level")
            if level in _LEVELS:
                parts.append(level)
            action = cd.get("action")
            if isinstance(action, str) and _WORD_RE.match(action):
                parts.append(action)
            for key in ("cause_commit_sha", "sha", "revision"):
                v = cd.get(key)
                if isinstance(v, str) and _SHA_RE.match(v):
                    parts.append(v[:7].lower())
                    break
            return " ".join(parts)
        parts = [kind]
        app = extract_app(event)
        if app:
            parts.append(app)
        rev = extract_revision(event)
        if rev:
            parts.append(rev[:7])
        title = cd.get("title")
        if isinstance(title, str) and title:
            parts.append(title[:80])
        return " ".join(parts)

    def _row(self, event: dict) -> dict:
        ctx = event["context"]
        rev = extract_revision(event)
        return {
            "id": ctx["id"],
            "type": ctx["type"],
            "timestamp": _iso(parse_timestamp(ctx["timestamp"])),
            "subject_id": (event.get("subject") or {}).get("id"),
            "app": extract_app(event),
            "revision": rev,
            "summary": self._summary(event),
            "customData": event.get("customData"),
        }

    def row(self, event: dict) -> dict:
        """The query-API row for one event (what the Grafana annotator posts)."""
        return self._row(event)

    def query(
        self,
        app: str | None = None,
        type: str | None = None,
        since: datetime | None = None,
        limit: int = 100,
        delivery_only: bool = False,
    ) -> list[dict]:
        with self._lock:
            indexed = list(enumerate(self._events))
        out: list[tuple[str, int, dict]] = []
        for idx, ev in indexed:
            if delivery_only and self.is_agent_event(ev):
                continue
            ctx = ev["context"]
            if type and not (ctx["type"] == type or short_type(ctx["type"]) == type or ctx["type"].startswith(type)):
                continue
            if app and extract_app(ev) != app:
                continue
            ts = parse_timestamp(ctx["timestamp"])
            if since and ts < since:
                continue
            out.append((_iso(ts), idx, ev))
        out.sort(key=lambda t: (t[0], t[1]), reverse=True)
        return [self._row(ev) for _, _, ev in out[: max(limit, 0)]]

    def incidents(self, app: str | None = None) -> list[dict]:
        with self._lock:
            rows = [dict(i) for i in self._incidents if not app or i["app"] == app]
        return rows
