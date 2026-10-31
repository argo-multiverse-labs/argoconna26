"""FastAPI app: ingest, query, timeline, incidents, annotations."""

from __future__ import annotations

import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, Query, Request
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import CollectorRegistry, Counter, Gauge, generate_latest, CONTENT_TYPE_LATEST

from .seed import seed
from .store import Store, parse_since, short_type
from .validate import ValidationError, validate_event


def create_app(
    store_path: Path | str | None = None,
    bridge_source: str | None = None,
    seed_fixture: Path | str | None = None,
) -> FastAPI:
    store_path = Path(store_path or os.environ.get("CDEVENTS_STORE", "/data/events.jsonl"))
    bridge_source = bridge_source if bridge_source is not None else os.environ.get("BRIDGE_EVENT_SOURCE", "")
    if not bridge_source.strip():
        # P16: refuse to start rather than serve a /timeline that lets the bridge's events through.
        raise ValueError("BRIDGE_EVENT_SOURCE must be set (the bridge's CloudEvents source)")
    seed_fixture = seed_fixture or os.environ.get("SEED_FIXTURE")
    store = Store(store_path, bridge_source=bridge_source)

    registry = CollectorRegistry()
    events_total = Counter("cdevents_sim_events_total", "Events by ingest result", ["result"], registry=registry)
    stored = Gauge("cdevents_sim_events_stored", "Events in the store", registry=registry)
    open_inc = Gauge("cdevents_sim_open_incidents", "Open incidents", registry=registry)
    stored.set_function(lambda: len(store._events))
    open_inc.set_function(lambda: sum(1 for i in store.incidents() if i["resolved_at"] is None))

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        if seed_fixture:
            seed(Path(seed_fixture), datetime.now(timezone.utc), store)
        yield

    app = FastAPI(title="cdevents-sim", lifespan=lifespan)
    app.state.store = store

    def _bad(msg: str) -> JSONResponse:
        return JSONResponse({"error": msg}, status_code=400)

    @app.post("/events")
    async def post_event(request: Request):
        try:
            event = await request.json()
        except ValueError:
            events_total.labels("invalid").inc()
            return _bad("body is not valid JSON")
        try:
            validate_event(event)
        except ValidationError as exc:
            events_total.labels("invalid").inc()
            return _bad(str(exc))
        res = store.add(event)
        events_total.labels(res.status).inc()
        if res.status == "duplicate":
            return JSONResponse({"duplicate": True}, status_code=200)
        if res.status == "dropped":
            return JSONResponse({"dropped": res.reason}, status_code=200)
        return JSONResponse({"id": res.id}, status_code=202)

    def _query(app_name, type_, since, limit, delivery_only):
        try:
            since_dt = parse_since(since, datetime.now(timezone.utc))
        except ValueError as exc:
            return _bad(str(exc))
        return store.query(app=app_name, type=type_, since=since_dt, limit=limit, delivery_only=delivery_only)

    @app.get("/events")
    def get_events(app: str | None = None, type: str | None = None, since: str | None = None,
                   limit: int = Query(100, ge=1, le=1000)):
        return _query(app, type, since, limit, False)

    @app.get("/timeline")
    def get_timeline(app: str | None = None, since: str | None = None,
                     limit: int = Query(100, ge=1, le=1000)):
        # Delivery events only (P16). No parameter turns the filter off, and
        # `type` is deliberately not offered either.
        return _query(app, None, since, limit, True)

    @app.get("/incidents")
    def get_incidents(app: str | None = None):
        return store.incidents(app)

    @app.get("/annotations")
    def get_annotations(app: str | None = None, since: str | None = None,
                        limit: int = Query(200, ge=1, le=1000)):
        rows = _query(app, None, since, limit, False)
        if isinstance(rows, JSONResponse):
            return rows
        return [
            {
                "time": int(datetime.fromisoformat(r["timestamp"].replace("Z", "+00:00")).timestamp() * 1000),
                "title": short_type(r["type"]),
                "text": r["summary"],
                "tags": [t for t in (short_type(r["type"]), r["app"]) if t],
            }
            for r in rows
        ]

    @app.get("/healthz")
    def healthz():
        return {"status": "ok"}

    @app.get("/metrics")
    def metrics():
        return PlainTextResponse(generate_latest(registry), media_type=CONTENT_TYPE_LATEST)

    return app
