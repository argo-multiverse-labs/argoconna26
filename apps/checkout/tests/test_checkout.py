import logging

import httpx
import pytest
import respx

from app.main import create_app

PRICING = "http://pricing.test:8080"


def env(**over):
    base = {"PRICING_URL": PRICING, "UPSTREAM_TIMEOUT_MS": "2000", "SLO_TARGET": "99"}
    base.update(over)
    return base


def pricing_route(mock: respx.MockRouter, delay_s: float):
    """Pricing answers after delay_s; a client timeout shorter than that raises, as httpx would."""

    def handler(request: httpx.Request) -> httpx.Response:
        timeout = request.extensions["timeout"]["read"]
        if timeout is not None and timeout < delay_s:
            raise httpx.ReadTimeout("slow", request=request)
        return httpx.Response(200, json={"sku": "demo-sku-001", "price_cents": 1999})

    return mock.get(f"{PRICING}/price").mock(side_effect=handler)


def client_for(app):
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


@pytest.fixture
def mock():
    with respx.mock(assert_all_called=False) as m:
        yield m


async def test_fast_upstream_returns_200(mock):
    pricing_route(mock, 0.01)
    async with client_for(create_app(env())) as c:
        r = await c.get("/checkout")
    assert r.status_code == 200
    assert r.json()["price_cents"] == 1999


async def test_slow_upstream_times_out_502(mock, caplog):
    pricing_route(mock, 0.350)
    caplog.set_level(logging.INFO)
    async with client_for(create_app(env(UPSTREAM_TIMEOUT_MS="200"))) as c:
        r = await c.get("/checkout")
    assert r.status_code == 502
    assert r.json() == {"error": "upstream timeout"}
    assert "upstream timeout after 200ms calling pricing" in [rec.getMessage() for rec in caplog.records]


async def test_2000ms_timeout_tolerates_350ms(mock):
    pricing_route(mock, 0.350)
    async with client_for(create_app(env(UPSTREAM_TIMEOUT_MS="2000"))) as c:
        r = await c.get("/checkout")
    assert r.status_code == 200


async def test_config_gauge_exported(mock):
    async with client_for(create_app(env(UPSTREAM_TIMEOUT_MS="200"))) as c:
        text = (await c.get("/metrics")).text
    assert "checkout_config_upstream_timeout_ms 200.0" in text


async def test_slo_gauge_from_env(mock):
    async with client_for(create_app(env(SLO_TARGET="99"))) as c:
        text = (await c.get("/metrics")).text
    assert "checkout_slo_target_percent 99.0" in text


def test_missing_timeout_env_fails_startup():
    e = env()
    del e["UPSTREAM_TIMEOUT_MS"]
    with pytest.raises(RuntimeError, match="UPSTREAM_TIMEOUT_MS"):
        create_app(e)


async def test_requests_counted_by_code(mock):
    pricing_route(mock, 0.350)
    async with client_for(create_app(env(UPSTREAM_TIMEOUT_MS="200"))) as c:
        await c.get("/checkout")
        await c.get("/checkout")
        text = (await c.get("/metrics")).text
    assert 'checkout_requests_total{code="502"} 2.0' in text


async def test_health_and_ready(mock):
    async with client_for(create_app(env())) as c:
        assert (await c.get("/healthz")).status_code == 200
        assert (await c.get("/readyz")).status_code == 200
