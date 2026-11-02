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

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST
from pydantic import ValidationError

from . import stagelog
from .autonomy import read_autonomy
from .config import Settings
from .events import CDEventsEmitter
from .forge import DryForge, Forge
from .forge.github import GitHubForge
from .github_auth import InstallationTokenProvider
from .holmes import HolmesClient
from .incidents import IncidentRegistry
from .metrics import Metrics
from .models import ArgoDegradedHook
from .pipeline import (
    Deps,
    Outcome,
    handle_incident,
    outcome_for_status,
    rehydrate_at_startup,
)
from .reconcile import Reconciler

log = logging.getLogger("bridge")

Handler = Callable[[ArgoDegradedHook], Awaitable[Any]]


async def _log_only_handler(hook: ArgoDegradedHook) -> None:
    """Used when the settings can't build the pipeline (for example `/healthz` alone)."""
    log.warning("incident %s received; the pipeline is not configured", hook.key)


_REQUIRED = ("github_repo", "github_app_id", "github_installation_id", "github_app_key_path", "holmes_url")


@dataclass
class Probes:
    """What the periodic refresh checks. All None when the pipeline is not configured."""

    forge: Forge | None = None
    tokens: InstallationTokenProvider | None = None
    holmes: HolmesClient | None = None


def build_handler(
    settings: Settings, registry: IncidentRegistry, metrics: Metrics, http: httpx.AsyncClient
) -> Handler:
    """The real pipeline over GitHub and HolmesGPT, or the log-only handler when unconfigured."""
    return build_pipeline(settings, registry, metrics, http)[0]


def build_pipeline(
    settings: Settings, registry: IncidentRegistry, metrics: Metrics, http: httpx.AsyncClient
) -> tuple[Handler, Probes]:
    missing = [name for name in _REQUIRED if not getattr(settings, name)]
    if missing:
        log.warning("pipeline not configured (missing %s); incidents are only logged", ", ".join(missing))
        return _log_only_handler, Probes()
    tokens = InstallationTokenProvider(
        settings.github_app_id,
        settings.github_installation_id,
        settings.github_app_key_path,
        repo=settings.github_repo,
        api_url=settings.github_api_url,
        http=http,
    )
    github = GitHubForge(
        settings.github_repo, tokens, api_url=settings.github_api_url, http=http, bot_login=settings.bot_login
    )
    forge: Forge = DryForge(github, settings.stage_cols) if settings.dry_forge else github
    holmes = HolmesClient(
        settings.holmes_url,
        settings.holmes_api_key.get_secret_value(),
        settings.holmes_model,
        settings.holmes_timeout_s,
        http=http,
    )
    deps = Deps(
        forge=forge,
        holmes=holmes,
        emitter=CDEventsEmitter(settings.cdevents_url, http=http),
        settings=settings,
        registry=registry,
        metrics=metrics,
    )

    async def handler(hook: ArgoDegradedHook) -> Outcome:
        return await handle_incident(hook, deps)

    return handler, Probes(forge=forge, tokens=tokens, holmes=holmes)


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
    probes: Probes = field(default_factory=Probes)
    metrics: Metrics | None = None
    # Set once the first refresh has finished (tests and readiness wait on it).
    refreshed: asyncio.Event = field(default_factory=asyncio.Event)

    async def refresh(self) -> None:
        """Probe GitHub and HolmesGPT for /status, and set the touchpoints gauge from
        aiops/autonomy.yaml, so panel 3 has data before the first incident (D8) and
        follows a promotion merge within one interval. Each step fails on its own."""
        p = self.probes
        if p.tokens is not None:
            try:
                await p.tokens.token()  # cached; minted only when missing or near expiry
                self.github_token_ok = True
            except Exception as exc:  # noqa: BLE001  any failure means "not ok"
                log.warning("github token check failed: %s", type(exc).__name__)
                self.github_token_ok = False
        if p.holmes is not None:
            try:
                self.holmes_reachable = await p.holmes.reachable()
            except Exception as exc:  # noqa: BLE001
                log.warning("holmes readiness check failed: %s", type(exc).__name__)
                self.holmes_reachable = False
        if p.forge is not None and self.metrics is not None:
            autonomy, failsafe_reason = await read_autonomy(p.forge, self.settings.tracked_branch)
            if failsafe_reason is None:
                self.metrics.set_touchpoints(autonomy.touchpoints)

    async def refresher(self) -> None:
        while True:
            try:
                await self.refresh()
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("status refresh failed")
            finally:
                self.refreshed.set()
            await asyncio.sleep(self.settings.status_refresh_s)  # a fixed period, not a wait for a condition

    async def worker(self) -> None:
        while True:
            hook = await self.queue.get()
            try:
                self.last_incident = {
                    "key": hook.key,
                    "received_at": hook.received_at.isoformat() if hook.received_at else None,
                    "state": "running",
                }
                result = await self.handler(hook)
                self.last_incident["state"] = "done"
                if isinstance(result, Outcome):
                    self.last_incident.update(outcome_for_status(result))
                    self.level_last_seen = result.level
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
    metrics: Metrics | None = None,
    probes: Probes | None = None,
) -> FastAPI:
    """`probes` is for tests that pass their own `handler` but still want a forge for the
    startup rehydrate and the status refresh; the real pipeline builds its own."""
    settings = settings or Settings()
    registry = registry or IncidentRegistry()
    metrics = metrics or Metrics(dryrun_summary_path=settings.dryrun_summary_path)
    http = httpx.AsyncClient(timeout=20.0)
    probes = probes or Probes()
    if handler is None:
        handler, probes = build_pipeline(settings, registry, metrics, http)
    state = BridgeState(settings=settings, handler=handler, registry=registry, probes=probes, metrics=metrics)

    @contextlib.asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        stagelog.configure()
        # The queue must belong to the running loop.
        state.queue = asyncio.Queue()
        state.refreshed = asyncio.Event()
        # Before the first webhook: open fix PRs mark their incidents as seen (Review Focus 5).
        if state.probes.forge is not None:
            await rehydrate_at_startup(state.registry, state.probes.forge)
        tasks = [
            asyncio.create_task(state.worker(), name="incident-worker"),
            asyncio.create_task(state.refresher(), name="status-refresh"),
        ]
        if probes.forge is not None:
            rec = Reconciler(
                probes.forge,
                metrics,
                CDEventsEmitter(settings.cdevents_url, http=http),
                app=settings.reconcile_app,
                source=settings.bridge_event_source,
                repo=settings.github_repo,
            )
            tasks.append(asyncio.create_task(rec.loop(settings.reconcile_interval_s), name="fix-pr-reconcile"))
        try:
            yield
        finally:
            for task in tasks:
                task.cancel()
            for task in tasks:
                with contextlib.suppress(asyncio.CancelledError):
                    await task
            await http.aclose()

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

    @app.get("/metrics")
    async def metrics_endpoint() -> Response:
        return Response(metrics.render(), media_type=CONTENT_TYPE_LATEST)

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
