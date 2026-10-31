"""FastAPI app: the Argo CD webhook, a single asyncio worker, health and status."""

from __future__ import annotations

import asyncio
import contextlib
import hmac
import logging
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import ValidationError

from . import stagelog
from .config import Settings
from .incidents import IncidentRegistry
from .models import ArgoDegradedHook

log = logging.getLogger("bridge")

Handler = Callable[[ArgoDegradedHook], Awaitable[Any]]


async def _log_only_handler(hook: ArgoDegradedHook) -> None:
    """Placeholder until the pipeline exists (Task 3.9)."""
    log.info("incident %s received; no pipeline configured", hook.key)


@dataclass
class BridgeState:
    settings: Settings
    handler: Handler
    registry: IncidentRegistry = field(default_factory=IncidentRegistry)
    queue: asyncio.Queue[ArgoDegradedHook] = field(default_factory=asyncio.Queue)
    level_last_seen: str | None = None
    last_incident: dict[str, Any] | None = None
    holmes_reachable: bool | None = None
    github_token_ok: bool | None = None

    async def worker(self) -> None:
        while True:
            hook = await self.queue.get()
            try:
                self.last_incident = {
                    "key": hook.key,
                    "received_at": hook.received_at.isoformat() if hook.received_at else None,
                    "state": "running",
                }
                await self.handler(hook)
                self.last_incident["state"] = "done"
            except asyncio.CancelledError:
                raise
            except Exception:  # one bad incident must not stop the worker
                log.exception("incident %s failed", hook.key)
                if self.last_incident is not None:
                    self.last_incident["state"] = "error"
            finally:
                self.queue.task_done()


def _authorized(request: Request, expected: str) -> bool:
    if not expected:
        return False  # fail closed when the Secret is missing
    header = request.headers.get("authorization", "")
    scheme, _, presented = header.partition(" ")
    if scheme.lower() != "bearer" or not presented:
        return False
    return hmac.compare_digest(presented.encode(), expected.encode())


def create_app(
    settings: Settings | None = None,
    handler: Handler | None = None,
    registry: IncidentRegistry | None = None,
) -> FastAPI:
    settings = settings or Settings()
    state = BridgeState(
        settings=settings,
        handler=handler or _log_only_handler,
        registry=registry or IncidentRegistry(),
    )

    @contextlib.asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        stagelog.configure()
        # The queue must belong to the running loop.
        state.queue = asyncio.Queue()
        task = asyncio.create_task(state.worker(), name="incident-worker")
        try:
            yield
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task

    app = FastAPI(title="aiops bridge", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.bridge = state

    @app.post("/hooks/argocd", status_code=202)
    async def argocd_hook(request: Request) -> JSONResponse:
        # Authenticate before reading the body, so an unauthenticated caller
        # learns nothing about the payload shape.
        if not _authorized(request, settings.webhook_token.get_secret_value()):
            return JSONResponse({"detail": "unauthorized"}, status_code=401)
        raw = await request.body()
        try:
            hook = ArgoDegradedHook.model_validate_json(raw)
        except ValidationError as exc:
            # 4xx, never 5xx: Argo Notifications retries on errors, and a bad
            # template would otherwise turn into a retry storm.
            fields = sorted({".".join(str(p) for p in e["loc"]) or "body" for e in exc.errors()})
            return JSONResponse({"detail": "invalid webhook body", "fields": fields}, status_code=422)
        hook.received_at = datetime.now(UTC)

        if not state.registry.mark_if_new(hook.key):
            log.info("duplicate incident %s ignored", hook.key)
            return JSONResponse({"incident": hook.key, "status": "duplicate"}, status_code=202)

        stagelog.emit("webhook", f"{hook.app} {hook.health.lower()}", settings.stage_cols)
        state.queue.put_nowait(hook)
        return JSONResponse({"incident": hook.key, "status": "queued"}, status_code=202)

    @app.get("/healthz", response_class=PlainTextResponse)
    async def healthz() -> str:
        return "ok"

    @app.get("/status")
    async def status() -> dict[str, Any]:
        return {
            "level_last_seen": state.level_last_seen,
            "queue_depth": state.queue.qsize(),
            "last_incident": state.last_incident,
            "holmes_reachable": state.holmes_reachable,
            "github_token_ok": state.github_token_ok,
            "dry_forge": settings.dry_forge,
        }

    return app
