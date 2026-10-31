"""Pricing: a deliberately slow dependency (about 350 ms) for checkout to call."""

import asyncio
import os
import random
from collections.abc import Awaitable, Callable

from fastapi import FastAPI, Response
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, Counter, generate_latest

MIN_DELAY_S = 0.30
MAX_DELAY_S = 0.45
MEAN_DELAY_S = 0.35
JITTER_S = 0.05


def _setup_tracing() -> None:
    """Export spans only when an OTLP endpoint is configured; otherwise no exporter."""
    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    if not endpoint:
        return
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    provider = TracerProvider()
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)


def create_app(
    sleep: Callable[[float], Awaitable] = asyncio.sleep,
    rng: random.Random | None = None,
) -> FastAPI:
    rng = rng or random.Random()
    registry = CollectorRegistry()
    requests = Counter(
        "pricing_requests", "Pricing requests by status code", ["code"], registry=registry
    )
    _setup_tracing()
    app = FastAPI(title="pricing")

    def next_delay() -> float:
        delay = MEAN_DELAY_S + rng.uniform(-JITTER_S, JITTER_S)
        return min(MAX_DELAY_S, max(MIN_DELAY_S, delay))

    @app.get("/price")
    async def price() -> dict:
        await sleep(next_delay())
        requests.labels(code="200").inc()
        return {"sku": "demo-sku-001", "price_cents": 1999}

    @app.get("/healthz")
    async def healthz() -> dict:
        return {"status": "ok"}

    @app.get("/metrics")
    async def metrics() -> Response:
        return Response(generate_latest(registry), media_type=CONTENT_TYPE_LATEST)

    return app


app = create_app()
