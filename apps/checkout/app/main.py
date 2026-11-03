"""Checkout: calls pricing with a timeout taken from config (UPSTREAM_TIMEOUT_MS)."""

import logging
from contextlib import asynccontextmanager
import os
from collections.abc import Mapping

import httpx
from fastapi import FastAPI, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, Counter, Gauge, generate_latest

log = logging.getLogger("checkout")


def _require(env: Mapping[str, str], key: str) -> str:
    value = env.get(key)
    if value is None or value == "":
        raise RuntimeError(f"missing required environment variable {key}")
    return value


def _require_number(env: Mapping[str, str], key: str) -> float:
    raw = _require(env, key)
    try:
        return float(raw)
    except ValueError:
        raise RuntimeError(f"{key} must be a number, got {raw!r}") from None


def _setup_tracing() -> None:
    """Export spans only when an OTLP endpoint is configured; otherwise no exporter."""
    if not os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT"):
        return
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    provider = TracerProvider()
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)


def create_app(env: Mapping[str, str] | None = None) -> FastAPI:
    """Settings are read once at startup. A missing value fails here, with no silent default."""
    env = os.environ if env is None else env
    pricing_url = _require(env, "PRICING_URL").rstrip("/")
    timeout_ms = _require_number(env, "UPSTREAM_TIMEOUT_MS")
    slo_target = _require_number(env, "SLO_TARGET")

    registry = CollectorRegistry()
    requests = Counter(
        "checkout_requests", "Checkout requests by status code", ["code"], registry=registry
    )
    Gauge(
        "checkout_config_upstream_timeout_ms",
        "UPSTREAM_TIMEOUT_MS as read at startup",
        registry=registry,
    ).set(timeout_ms)
    Gauge(
        "checkout_slo_target_percent",
        "Success-rate SLO target from the pod label",
        registry=registry,
    ).set(slo_target)

    _setup_tracing()
    client = httpx.AsyncClient()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        yield
        await client.aclose()

    app = FastAPI(title="checkout", lifespan=lifespan)

    @app.get("/checkout")
    async def checkout() -> Response:
        try:
            r = await client.get(f"{pricing_url}/price", timeout=timeout_ms / 1000)
            r.raise_for_status()
        except httpx.TimeoutException:
            log.error("upstream timeout after %dms calling pricing", int(timeout_ms))
            requests.labels(code="502").inc()
            return JSONResponse({"error": "upstream timeout"}, status_code=502)
        except httpx.HTTPError:
            log.error("upstream error calling pricing")
            requests.labels(code="502").inc()
            return JSONResponse({"error": "upstream error"}, status_code=502)
        requests.labels(code="200").inc()
        return JSONResponse(r.json())

    @app.get("/healthz")
    async def healthz() -> dict:
        return {"status": "ok"}

    @app.get("/readyz")
    async def readyz() -> dict:
        return {"status": "ready"}

    @app.get("/metrics")
    async def metrics() -> Response:
        return Response(generate_latest(registry), media_type=CONTENT_TYPE_LATEST)

    return app
