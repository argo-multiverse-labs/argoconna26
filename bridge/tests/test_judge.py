"""Task 6.1: the LLM judge, through LiteLLM's `judge` alias. The client is a stub; no network."""

from __future__ import annotations

import json

import httpx
import pytest
import respx
from bridge.judge import JUDGE_MODEL, JudgeResult, LiteLLMChat, judge, judge_detail
from bridge.rca import RCA

RCA_OK = RCA.model_validate({
    "root_cause": "PR-242 cut UPSTREAM_TIMEOUT_MS to 200.",
    "cause_commit_sha": "c" * 40,
    "evidence": ["ConfigMap: checkout-config holds 200"],
    "delivery_context": "CHG-K7Q2ZB merged 3 minutes before the abort.",
    "confidence": 0.9,
    "proposed_patch": {"file": "apps/checkout/config/checkout-config.yaml", "key": "UPSTREAM_TIMEOUT_MS",
                       "from": "200", "to": "2000"},
})
BUNDLE = "Expected cause: cccc... (CHG-K7Q2ZB), UPSTREAM_TIMEOUT_MS 200 -> 2000."


class StubChat:
    def __init__(self, reply: object) -> None:
        self.reply = reply
        self.bodies: list[dict] = []

    async def chat(self, body: dict) -> dict:
        self.bodies.append(body)
        if isinstance(self.reply, BaseException):
            raise self.reply
        return self.reply  # type: ignore[return-value]


def completion(content: object) -> dict:
    return {"choices": [{"message": {"role": "assistant", "content": content}}]}


async def test_judge_parses_verdict():
    for verdict in ("correct", "partial", "wrong"):
        client = StubChat(completion(json.dumps({"verdict": verdict, "reason": "matches the cause"})))
        assert await judge(RCA_OK, BUNDLE, client) == verdict
    body = client.bodies[0]
    assert body["model"] == JUDGE_MODEL == "judge"
    fmt = body["response_format"]
    assert fmt["type"] == "json_schema" and fmt["json_schema"]["strict"] is True
    schema = fmt["json_schema"]["schema"]
    assert schema["additionalProperties"] is False
    assert sorted(schema["required"]) == ["reason", "verdict"]
    assert schema["properties"]["verdict"]["enum"] == ["correct", "partial", "wrong"]
    # The judge model (Opus 5.5) rejects sampling parameters, so none is sent (O2).
    assert "temperature" not in body and "top_p" not in body
    prompt = "\n".join(m["content"] for m in body["messages"])
    assert BUNDLE in prompt and RCA_OK.cause_commit_sha in prompt and "CHG-K7Q2ZB" in prompt


async def test_judge_detail_keeps_reason():
    client = StubChat(completion('```json\n{"verdict": "partial", "reason": "right SHA, wrong value"}\n```'))
    assert await judge_detail(RCA_OK, BUNDLE, client) == JudgeResult("partial", "right SHA, wrong value")


@pytest.mark.parametrize(
    "reply",
    [
        completion("not json at all"),
        completion(json.dumps({"verdict": "maybe", "reason": "x"})),
        completion(json.dumps({"reason": "no verdict"})),
        completion(json.dumps(["correct"])),
        completion(None),
        {"choices": []},
        {"error": {"message": "budget exceeded"}},
        "not a dict",
        RuntimeError("connection reset"),
        httpx.ConnectError("refused"),
    ],
)
async def test_judge_bad_output_is_wrong_not_crash(reply):
    result = await judge_detail(RCA_OK, BUNDLE, StubChat(reply))
    assert result.verdict == "wrong"
    assert result.reason.startswith("judge error")
    assert await judge(RCA_OK, BUNDLE, StubChat(reply)) == "wrong"


async def test_judge_none_rca_is_wrong_without_a_call():
    client = StubChat(completion(json.dumps({"verdict": "correct", "reason": "x"})))
    assert await judge(None, BUNDLE, client) == "wrong"
    assert client.bodies == []


async def test_litellm_chat_posts_with_bearer_and_never_echoes_the_body():
    with respx.mock(assert_all_called=True) as router:
        route = router.post("http://litellm.test/v1/chat/completions").mock(
            return_value=httpx.Response(200, json=completion('{"verdict":"correct","reason":"ok"}'))
        )
        async with httpx.AsyncClient() as http:
            chat = LiteLLMChat("http://litellm.test/v1/", "sk-judge-test", http=http)
            assert "sk-judge-test" not in repr(chat)
            out = await chat.chat({"model": "judge", "messages": []})
    assert out["choices"][0]["message"]["content"]
    assert route.calls[0].request.headers["Authorization"] == "Bearer sk-judge-test"

    with respx.mock() as router:
        router.post("http://litellm.test/v1/chat/completions").mock(
            return_value=httpx.Response(400, json={"error": "secret detail"})
        )
        async with httpx.AsyncClient() as http:
            chat = LiteLLMChat("http://litellm.test/v1", "sk-judge-test", http=http)
            with pytest.raises(httpx.HTTPStatusError) as err:
                await chat.chat({"model": "judge", "messages": []})
    assert "secret detail" not in str(err.value)
