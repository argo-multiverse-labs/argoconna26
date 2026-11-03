"""Loadgen: steady GET traffic at RPS against TARGET_URL. Quiet; one summary line every 30 s."""

import asyncio
import os
import time
from collections.abc import Callable

import httpx

SUMMARY_EVERY_S = 30.0
MAX_IN_FLIGHT = 500


class RealClock:
    def now(self) -> float:
        return time.monotonic()

    async def sleep(self, dt: float) -> None:
        await asyncio.sleep(dt)


async def run(target: str, rps: float, client, clock, stop: Callable[[], bool]) -> None:
    """Issue requests on a fixed schedule so a slow upstream does not lower the rate.
    A failed request is counted, never raised."""
    interval = 1.0 / rps
    counts = {"ok": 0, "err": 0, "dropped": 0}
    in_flight: set[asyncio.Task] = set()

    async def one() -> None:
        try:
            r = await client.get(target)
            counts["ok" if r.status_code < 400 else "err"] += 1
        except Exception:
            counts["err"] += 1

    start = clock.now()
    next_at = start
    next_summary = start + SUMMARY_EVERY_S
    while not stop():
        if len(in_flight) >= MAX_IN_FLIGHT:
            counts["dropped"] += 1
        else:
            task = asyncio.create_task(one())
            in_flight.add(task)
            task.add_done_callback(in_flight.discard)
        await asyncio.sleep(0)  # let finished requests report before a summary
        next_at += interval
        now = clock.now()
        if now >= next_summary:
            print(
                f"loadgen: {counts['ok']} ok, {counts['err']} failed, {counts['dropped']} dropped",
                flush=True,
            )
            next_summary += SUMMARY_EVERY_S
        await clock.sleep(next_at - now)
    if in_flight:
        await asyncio.gather(*in_flight, return_exceptions=True)


def make_client() -> httpx.AsyncClient:
    """No keep-alive: kube-proxy balances connections, so a new connection per request
    spreads the load over every pod, a fresh canary pod included."""
    return httpx.AsyncClient(timeout=5.0, limits=httpx.Limits(max_keepalive_connections=0))


async def _main() -> None:
    target = os.environ["TARGET_URL"]
    rps = float(os.environ.get("RPS", "20"))
    async with make_client() as client:
        await run(target, rps, client, RealClock(), lambda: False)


if __name__ == "__main__":
    asyncio.run(_main())
