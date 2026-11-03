"""Grafana annotations for stored events.

The annotator takes the same row the query API returns, so the annotation text is the
fixed-field summary the store builds (spec 7.1): model text never reaches a panel.
Failures are logged and retried; they never reach the caller.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from datetime import datetime
from pathlib import Path

import httpx

from .store import short_type

log = logging.getLogger("cdevents_sim.grafana")

ATTEMPTS = 3
BACKOFF_S = 0.5


class GrafanaAnnotator:
    def __init__(
        self,
        base_url: str,
        token: str | None = None,
        dashboard_uid: str = "trust-ladder",
        panel_id: int = 1,
        *,
        token_file: Path | str | None = None,
        timeout_s: float = 5.0,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ):
        self.base_url = base_url.rstrip("/")
        self._token = token
        self._token_file = Path(token_file) if token_file else None
        self.dashboard_uid = dashboard_uid
        self.panel_id = panel_id
        self._timeout_s = timeout_s
        self._sleep = sleep

    def _read_token(self) -> str | None:
        """A mounted Secret file is read on every call, so a token created after the pod
        started (make grafana-token runs after the install) is picked up without a restart."""
        if self._token_file is not None:
            try:
                value = self._token_file.read_text().strip()
            except OSError:
                return None
            return value or None
        return self._token or None

    def payload(self, row: dict) -> dict:
        ts = datetime.fromisoformat(row["timestamp"])
        tags = [t for t in (short_type(row["type"]), row.get("app")) if t]
        return {
            "dashboardUID": self.dashboard_uid,
            "panelId": self.panel_id,
            "time": int(ts.timestamp() * 1000),
            "tags": tags,
            "text": row["summary"],
        }

    async def annotate(self, row: dict) -> None:
        token = self._read_token()
        if not token:
            log.warning("grafana annotation skipped: no token yet (run make grafana-token)")
            return
        body = self.payload(row)
        headers = {"Authorization": f"Bearer {token}"}
        for attempt in range(1, ATTEMPTS + 1):
            try:
                async with httpx.AsyncClient(timeout=self._timeout_s) as client:
                    r = await client.post(f"{self.base_url}/api/annotations", json=body, headers=headers)
                if r.status_code < 300:
                    return
                err = f"HTTP {r.status_code}"
            except httpx.HTTPError as exc:
                err = type(exc).__name__  # never the message: it can carry the URL
            log.warning("grafana annotation attempt %d/%d failed: %s", attempt, ATTEMPTS, err)
            if attempt < ATTEMPTS:
                await self._sleep(BACKOFF_S * 2 ** (attempt - 1))
        log.error("grafana annotation for event %s dropped after %d attempts", row.get("id"), ATTEMPTS)
