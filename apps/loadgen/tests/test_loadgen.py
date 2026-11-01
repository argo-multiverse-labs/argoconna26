import httpx

from app.main import run


class FakeClock:
    """Virtual time: sleep advances it, nothing really waits."""

    def __init__(self):
        self.t = 0.0

    def now(self) -> float:
        return self.t

    async def sleep(self, dt: float) -> None:
        self.t += max(0.0, dt)


class CountingClient:
    def __init__(self, fail_every: int = 0):
        self.calls = 0
        self.fail_every = fail_every

    async def get(self, url, **kw):
        self.calls += 1
        if self.fail_every and self.calls % self.fail_every == 0:
            raise httpx.ConnectError("boom")
        return httpx.Response(200)


async def test_rate_matches_rps():
    clock, client = FakeClock(), CountingClient()
    await run("http://t/checkout", 20, client, clock, lambda: clock.now() >= 10)
    assert abs(client.calls - 200) <= 2


async def test_errors_do_not_stop_loop():
    clock, client = FakeClock(), CountingClient(fail_every=3)
    await run("http://t/checkout", 20, client, clock, lambda: clock.now() >= 10)
    assert abs(client.calls - 200) <= 2


async def test_quiet_per_request_with_summary_every_30s(capsys):
    clock, client = FakeClock(), CountingClient(fail_every=10)
    await run("http://t/checkout", 20, client, clock, lambda: clock.now() >= 65)
    lines = capsys.readouterr().out.strip().splitlines()
    assert len(lines) == 2  # at 30 s and 60 s, nothing per request
    assert all(line.startswith("loadgen:") for line in lines)


def test_client_opens_a_new_connection_per_request():
    # kube-proxy balances connections, not requests. A pooled keep-alive client stays on the
    # pods it first reached, so a new canary pod would see no traffic and the analysis
    # would pass on an empty result.
    from app.main import make_client

    client = make_client()
    try:
        pool = client._transport._pool
        assert pool._max_keepalive_connections == 0
    finally:
        import asyncio

        asyncio.run(client.aclose())
