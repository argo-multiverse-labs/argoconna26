"""HolmesGPT client: `POST /api/chat` with a strict `response_format`."""

from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlsplit

import httpx
from pydantic import ValidationError

from .rca import RCA, rca_json_schema

log = logging.getLogger("bridge.holmes")


class HolmesError(Exception):
    """HolmesGPT did not produce a usable RCA."""


class HolmesTimeout(HolmesError):
    """No answer within `timeout_s` (wall clock, whole call)."""


class HolmesBadOutput(HolmesError):
    """An HTTP error, or an answer that isn't a valid RCA."""


@dataclass
class HolmesResult:
    rca: RCA
    tool_calls: list[str] = field(default_factory=list)
    raw_analysis: str = ""
    latency_s: float = 0.0


def _strip_fence(text: str) -> str:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = stripped.split("\n", 1)[1] if "\n" in stripped else ""
        if stripped.rstrip().endswith("```"):
            stripped = stripped.rstrip()[:-3]
    return stripped.strip()


def tool_call_label(call: dict[str, Any]) -> str:
    """A short, host-free label for the stage log: `GET /timeline`, `prometheus range query`."""
    result = call.get("result") or {}
    url = result.get("url") or (result.get("params") or {}).get("url")
    if url:
        method = str((result.get("params") or {}).get("method") or "GET").upper()
        label = f"{method} {urlsplit(str(url)).path or '/'}"
    else:
        name = str(call.get("tool_name") or call.get("description") or "tool")
        words = name.replace("_", " ").split()
        if words and words[0] in {"execute", "run", "call", "get", "fetch"} and len(words) > 1:
            words = words[1:]
        label = " ".join(words)
    if result.get("status") == "error":
        label += " (refused)"
    return label


class HolmesClient:
    def __init__(
        self,
        url: str,
        api_key: str,
        model: str = "rca",
        timeout_s: float = 115,
        *,
        http: httpx.AsyncClient | None = None,
    ) -> None:
        self.url = url.rstrip("/")
        self._api_key = api_key
        self.model = model
        self.timeout_s = float(timeout_s)
        self._http = http or httpx.AsyncClient()

    def __repr__(self) -> str:
        return f"HolmesClient(url={self.url!r}, model={self.model!r}, timeout_s={self.timeout_s})"

    def request_body(self, prompt: str) -> dict[str, Any]:
        return {
            "ask": prompt,
            "model": self.model,
            "response_format": {
                "type": "json_schema",
                "json_schema": {"name": "RCA", "strict": True, "schema": rca_json_schema()},
            },
            "behavior_controls": {"todowrite_instructions": False, "todowrite_reminder": False},
        }

    async def investigate(self, prompt: str) -> HolmesResult:
        started = time.monotonic()
        try:
            async with asyncio.timeout(self.timeout_s):
                response = await self._http.post(
                    f"{self.url}/api/chat",
                    json=self.request_body(prompt),
                    headers={"X-API-Key": self._api_key},
                    timeout=httpx.Timeout(self.timeout_s),
                )
        except (TimeoutError, httpx.TimeoutException):
            raise HolmesTimeout(f"no answer within {self.timeout_s:g} s") from None
        except httpx.HTTPError as exc:
            raise HolmesBadOutput(f"request failed: {type(exc).__name__}") from None
        latency = time.monotonic() - started

        if response.status_code != 200:
            # The body is not echoed: it could carry anything.
            raise HolmesBadOutput(f"HTTP {response.status_code}")
        try:
            envelope = response.json()
        except ValueError:
            raise HolmesBadOutput("response is not JSON") from None
        if not isinstance(envelope, dict):
            raise HolmesBadOutput("response is not an object")

        analysis = envelope.get("analysis")
        if isinstance(analysis, dict):
            raw, data = json.dumps(analysis), analysis
        elif isinstance(analysis, str):
            raw = analysis
            try:
                data = json.loads(_strip_fence(analysis))
            except ValueError:
                raise HolmesBadOutput("analysis is not JSON") from None
        else:
            raise HolmesBadOutput("no analysis in response")
        try:
            rca = RCA.model_validate(data)
        except ValidationError as exc:
            fields = sorted({".".join(str(p) for p in e["loc"]) or "analysis" for e in exc.errors()})
            raise HolmesBadOutput(f"analysis does not match the RCA schema: {', '.join(fields)}") from None

        calls = [tool_call_label(c) for c in envelope.get("tool_calls") or [] if isinstance(c, dict)]
        log.info("holmes answered in %.1f s with %d tool calls", latency, len(calls))
        return HolmesResult(rca=rca, tool_calls=calls, raw_analysis=raw, latency_s=latency)
