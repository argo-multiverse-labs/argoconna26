"""The dry-run LLM judge (Task 6.1): a second opinion on one RCA, through LiteLLM's `judge` alias.

The judge sees the incident's known answer and facts (the evidence bundle the harness
builds) and the RCA, and answers with a strict `{verdict, reason}` object. It is reported
next to the deterministic score and never changes it.

No sampling parameter is sent. The plan asked for temperature 0, but the `judge` alias maps
to Claude Opus 5.5, which rejects `temperature`, `top_p` and `top_k` (as O2 found for the
build model), so the judge runs at the provider's default and the report says so.

Any failure (transport, HTTP status, no content, not JSON, an unknown verdict) gives the
verdict `wrong` with a reason starting "judge error", never an exception: a broken judge
must not stop a dry-run batch, and it must not count as a pass either.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Any, Literal, Protocol, get_args

import httpx
from jinja2 import Environment, PackageLoader, StrictUndefined

from .rca import RCA

log = logging.getLogger("bridge.judge")

Verdict = Literal["correct", "partial", "wrong"]
VERDICTS: tuple[str, ...] = get_args(Verdict)
#: The LiteLLM alias (demo.env LLM_ALIAS_JUDGE).
JUDGE_MODEL = "judge"
JUDGE_MAX_TOKENS = 1024


@dataclass(frozen=True)
class JudgeResult:
    verdict: Verdict
    reason: str


class ChatClient(Protocol):
    async def chat(self, body: dict[str, Any]) -> dict[str, Any]: ...


class LiteLLMChat:
    """`POST <base>/chat/completions` on the LiteLLM proxy with a virtual key (the `judge-llm` key)."""

    def __init__(self, base_url: str, api_key: str, *, http: httpx.AsyncClient | None = None,
                 timeout_s: float = 120.0) -> None:
        self.base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._timeout = httpx.Timeout(timeout_s)
        self._http = http or httpx.AsyncClient()

    def __repr__(self) -> str:
        return f"LiteLLMChat(base_url={self.base_url!r})"

    async def chat(self, body: dict[str, Any]) -> dict[str, Any]:
        response = await self._http.post(
            f"{self.base_url}/chat/completions",
            json=body,
            headers={"Authorization": f"Bearer {self._api_key}"},
            timeout=self._timeout,
        )
        response.raise_for_status()  # the message names the status and URL, never the body
        data = response.json()
        if not isinstance(data, dict):
            raise TypeError("response is not an object")
        return data


def judge_schema() -> dict[str, Any]:
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["verdict", "reason"],
        "properties": {
            "verdict": {"type": "string", "enum": list(VERDICTS)},
            "reason": {"type": "string"},
        },
    }


_env = Environment(
    loader=PackageLoader("bridge", "templates"), autoescape=False, undefined=StrictUndefined,
    keep_trailing_newline=True,
)


def request_body(rca: RCA, evidence_bundle: str, model: str = JUDGE_MODEL) -> dict[str, Any]:
    prompt = _env.get_template("judge_prompt.md.j2").render(
        evidence_bundle=evidence_bundle,
        rca_json=json.dumps(rca.model_dump(by_alias=True), indent=2, ensure_ascii=False),
    )
    return {
        "model": model,
        "max_tokens": JUDGE_MAX_TOKENS,
        "messages": [{"role": "user", "content": prompt}],
        "response_format": {
            "type": "json_schema",
            "json_schema": {"name": "Verdict", "strict": True, "schema": judge_schema()},
        },
    }


def _strip_fence(text: str) -> str:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = stripped.split("\n", 1)[1] if "\n" in stripped else ""
        if stripped.rstrip().endswith("```"):
            stripped = stripped.rstrip()[:-3]
    return stripped.strip()


def _parse(reply: object) -> JudgeResult:
    if not isinstance(reply, dict):
        raise TypeError("reply is not an object")
    choices = reply.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        raise ValueError("no choices")
    content = (choices[0].get("message") or {}).get("content")
    if not isinstance(content, str):
        raise TypeError("no content")
    data = json.loads(_strip_fence(content))
    if not isinstance(data, dict):
        raise TypeError("verdict is not an object")
    verdict, reason = data.get("verdict"), data.get("reason", "")
    if verdict not in VERDICTS:
        raise ValueError("unknown verdict")
    return JudgeResult(verdict, " ".join(str(reason).split()))  # type: ignore[arg-type]


async def judge_detail(rca: RCA | None, evidence_bundle: str, client: ChatClient,
                       model: str = JUDGE_MODEL) -> JudgeResult:
    """The verdict and the judge's one-sentence reason. None as the RCA is `wrong`, with no call."""
    if rca is None:
        return JudgeResult("wrong", "no RCA to judge")
    try:
        reply = await client.chat(request_body(rca, evidence_bundle, model))
        return _parse(reply)
    except Exception as exc:  # noqa: BLE001  a judge failure is a verdict, never a crash
        log.warning("judge failed: %s", type(exc).__name__)
        return JudgeResult("wrong", f"judge error: {type(exc).__name__}")


async def judge(rca: RCA | None, evidence_bundle: str, client: ChatClient,
                model: str = JUDGE_MODEL) -> Verdict:
    return (await judge_detail(rca, evidence_bundle, client, model)).verdict
