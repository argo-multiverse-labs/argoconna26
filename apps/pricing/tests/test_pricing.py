import random

import httpx
import pytest

from app.main import create_app


class RecordingSleep:
    def __init__(self):
        self.delays: list[float] = []

    async def __call__(self, delay: float) -> None:
        self.delays.append(delay)


def client_for(app):
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


async def test_delay_within_bounds():
    sleep = RecordingSleep()
    app = create_app(sleep=sleep, rng=random.Random(42))
    async with client_for(app) as c:
        for _ in range(1000):
            r = await c.get("/price")
            assert r.status_code == 200
    assert len(sleep.delays) == 1000
    assert all(0.30 <= d <= 0.45 for d in sleep.delays)


async def test_never_reaches_one_second():
    sleep = RecordingSleep()
    # an rng that always returns a huge deviation must still be clamped
    class Wild(random.Random):
        def gauss(self, mu, sigma):
            return 10.0

        def uniform(self, a, b):
            return 10.0

    app = create_app(sleep=sleep, rng=Wild())
    async with client_for(app) as c:
        await c.get("/price")
    assert sleep.delays and max(sleep.delays) < 1.0
    assert max(sleep.delays) <= 0.45


async def test_price_shape():
    app = create_app(sleep=RecordingSleep(), rng=random.Random(1))
    async with client_for(app) as c:
        body = (await c.get("/price")).json()
    assert isinstance(body["sku"], str)
    assert isinstance(body["price_cents"], int)


async def test_metrics_counts_by_code():
    app = create_app(sleep=RecordingSleep(), rng=random.Random(1))
    async with client_for(app) as c:
        for _ in range(3):
            await c.get("/price")
        text = (await c.get("/metrics")).text
    assert 'pricing_requests_total{code="200"} 3.0' in text


async def test_healthz_ok():
    app = create_app(sleep=RecordingSleep(), rng=random.Random(1))
    async with client_for(app) as c:
        r = await c.get("/healthz")
    assert r.status_code == 200
