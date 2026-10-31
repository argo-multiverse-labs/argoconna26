"""Task 3.6: the HolmesGPT client and the runbook prompt."""

from __future__ import annotations

import asyncio
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import pytest
import respx

from bridge.holmes import HolmesBadOutput, HolmesClient, HolmesResult, HolmesTimeout
from bridge.models import ArgoDegradedHook
from bridge.prompt import build_prompt, live_window
from bridge.rca import RCA

from .conftest import hook_body

URL = "http://holmes.test"
FIXTURES = Path(__file__).parent / "fixtures" / "holmes"
RCA_JSON = {
    "root_cause": "The canary got UPSTREAM_TIMEOUT_MS=200 from a config change.",
    "cause_commit_sha": "c" * 40,
    "evidence": ["Prometheus: canary pods report 200", "ConfigMap: 200"],
    "delivery_context": "CHG-ab12cd merged 3 days before the abort",
    "confidence": 0.86,
    "proposed_patch": {
        "file": "apps/checkout/config/checkout-config.yaml",
        "key": "UPSTREAM_TIMEOUT_MS",
        "from": "200",
        "to": "2000",
    },
}


def envelope(analysis: object, tool_calls: list | None = None) -> dict:
    return {
        "analysis": analysis,
        "conversation_history": [],
        "tool_calls": tool_calls or [],
        "follow_up_actions": [],
        "pending_approvals": [],
        "metadata": {},
    }


@pytest.fixture
async def client():
    async with httpx.AsyncClient() as http:
        yield HolmesClient(URL, "holmes-test-key", "rca", 5, http=http)


@respx.mock(assert_all_mocked=True)
async def test_request_shape(respx_mock, client: HolmesClient) -> None:
    route = respx_mock.post(f"{URL}/api/chat").mock(
        return_value=httpx.Response(200, json=envelope(json.dumps(RCA_JSON)))
    )
    await client.investigate("why is checkout degraded?")
    request = route.calls[0].request
    assert request.url.path == "/api/chat"
    assert request.headers["X-API-Key"] == "holmes-test-key"
    body = json.loads(request.content)
    assert body["ask"] == "why is checkout degraded?"
    assert body["model"] == "rca"
    rf = body["response_format"]
    assert rf["type"] == "json_schema"
    assert rf["json_schema"]["name"] == "RCA"
    assert rf["json_schema"]["strict"] is True
    assert body["behavior_controls"] == {"todowrite_instructions": False, "todowrite_reminder": False}


@respx.mock(assert_all_mocked=True)
async def test_analysis_string_parsed(respx_mock, client: HolmesClient) -> None:
    respx_mock.post(f"{URL}/api/chat").mock(
        return_value=httpx.Response(200, json=envelope(json.dumps(RCA_JSON)))
    )
    result = await client.investigate("q")
    assert isinstance(result, HolmesResult)
    assert isinstance(result.rca, RCA)
    assert result.rca.cause_commit_sha == "c" * 40
    assert result.rca.proposed_patch.to_value == "2000"
    assert result.raw_analysis == json.dumps(RCA_JSON)
    assert result.latency_s >= 0


@respx.mock(assert_all_mocked=True)
async def test_fenced_analysis_parsed(respx_mock, client: HolmesClient) -> None:
    fenced = "```json\n" + json.dumps(RCA_JSON) + "\n```"
    respx_mock.post(f"{URL}/api/chat").mock(return_value=httpx.Response(200, json=envelope(fenced)))
    assert (await client.investigate("q")).rca.confidence == 0.86


@respx.mock(assert_all_mocked=True)
async def test_timeout_raises_holmes_timeout(respx_mock, client: HolmesClient) -> None:
    respx_mock.post(f"{URL}/api/chat").mock(side_effect=httpx.ReadTimeout("slow"))
    with pytest.raises(HolmesTimeout):
        await client.investigate("q")


async def test_overall_deadline_raises_holmes_timeout() -> None:
    """The cap is wall-clock for the whole call, not per socket read."""
    started = asyncio.Event()

    async def never_answers(request: httpx.Request) -> httpx.Response:
        started.set()
        await asyncio.Event().wait()  # blocks until cancelled by the client's deadline
        raise AssertionError("unreachable")

    # The route is cancelled mid-call, so respx never counts it as called.
    with respx.mock(assert_all_mocked=True, assert_all_called=False) as mock:
        mock.post(f"{URL}/api/chat").mock(side_effect=never_answers)
        async with httpx.AsyncClient() as http:
            client = HolmesClient(URL, "k", "rca", 0.2, http=http)
            with pytest.raises(HolmesTimeout):
                await client.investigate("q")
    assert started.is_set()


@pytest.mark.parametrize(
    "analysis",
    [
        "not json",
        json.dumps({"root_cause": "only one field"}),
        json.dumps({**RCA_JSON, "confidence": 7}),
        None,
    ],
)
async def test_bad_json_raises_bad_output(client: HolmesClient, analysis: object) -> None:
    with respx.mock(assert_all_mocked=True) as mock:
        mock.post(f"{URL}/api/chat").mock(return_value=httpx.Response(200, json=envelope(analysis)))
        with pytest.raises(HolmesBadOutput):
            await client.investigate("q")


@pytest.mark.parametrize("status", [400, 401, 500, 503])
async def test_http_error_is_not_a_result(client: HolmesClient, status: int) -> None:
    with respx.mock(assert_all_mocked=True) as mock:
        mock.post(f"{URL}/api/chat").mock(return_value=httpx.Response(status, text="nope"))
        with pytest.raises(HolmesBadOutput):
            await client.investigate("q")


async def test_api_key_not_in_errors_or_repr(client: HolmesClient) -> None:
    assert "holmes-test-key" not in repr(client)
    with respx.mock(assert_all_mocked=True) as mock:
        mock.post(f"{URL}/api/chat").mock(return_value=httpx.Response(401, text="bad key holmes-test-key"))
        with pytest.raises(HolmesBadOutput) as excinfo:
            await client.investigate("q")
    assert "holmes-test-key" not in str(excinfo.value)


@respx.mock(assert_all_mocked=True)
async def test_tool_calls_extracted_for_stagelog(respx_mock, client: HolmesClient) -> None:
    calls = [
        {
            "tool_call_id": "1",
            "tool_name": "cdevents_timeline_request",
            "toolset_name": "cdevents-timeline",
            "description": "HTTP GET http://cdevents-sim.aiops.svc:8080/timeline?app=checkout",
            "result": {
                "status": "success",
                "url": "http://cdevents-sim.aiops.svc:8080/timeline?app=checkout&since=x",
            },
        },
        {
            "tool_call_id": "2",
            "tool_name": "execute_prometheus_range_query",
            "toolset_name": "prometheus/metrics",
            "description": "Prometheus range query",
            "result": {"status": "success"},
        },
        {
            "tool_call_id": "3",
            "tool_name": "cdevents_timeline_request",
            "toolset_name": "cdevents-timeline",
            "description": "HTTP GET http://cdevents-sim.aiops.svc:8080/events",
            "result": {"status": "error", "url": "http://cdevents-sim.aiops.svc:8080/events?app=checkout"},
        },
    ]
    respx_mock.post(f"{URL}/api/chat").mock(
        return_value=httpx.Response(200, json=envelope(json.dumps(RCA_JSON), calls))
    )
    result = await client.investigate("q")
    assert result.tool_calls == [
        "GET /timeline",
        "prometheus range query",
        "GET /events (refused)",
    ]
    for label in result.tool_calls:
        assert "cdevents-sim" not in label  # no hostnames on the projector
        assert "?" not in label


@pytest.mark.parametrize("name", ["rca_ok.json", "rca_toolcall_timeline.json", "rca_toolcall_refused_events.json"])
async def test_recorded_spike_fixtures_parse(client: HolmesClient, name: str) -> None:
    raw = json.loads((FIXTURES / name).read_text())
    raw.pop("_fixture", None)
    with respx.mock(assert_all_mocked=True) as mock:
        mock.post(f"{URL}/api/chat").mock(return_value=httpx.Response(200, json=raw))
        result = await client.investigate("q")
    assert len(result.rca.cause_commit_sha) == 40
    assert result.raw_analysis == raw["analysis"]
    assert len(result.tool_calls) == len(raw["tool_calls"])


def test_recorded_fixtures_exist() -> None:
    assert sorted(p.name for p in FIXTURES.glob("rca_*.json")) == [
        "rca_ok.json",
        "rca_toolcall_refused_events.json",
        "rca_toolcall_timeline.json",
    ]


# --- the prompt ---------------------------------------------------------------

RECEIVED = datetime(2026, 11, 9, 17, 42, 5, tzinfo=UTC)


def _hook() -> ArgoDegradedHook:
    hook = ArgoDegradedHook.model_validate(hook_body(namespace="demo"))
    hook.received_at = RECEIVED
    return hook


def test_prompt_mentions_timeline_and_forbids_ips() -> None:
    prompt = build_prompt(_hook(), live_window(RECEIVED))
    assert "cdevents-timeline" in prompt
    assert "GET http://cdevents-sim.aiops.svc:8080/timeline" in prompt
    assert "change_ref" in prompt
    lowered = prompt.lower()
    assert "ip address" in lowered
    assert "secret" in lowered
    assert "40-character" in prompt


def test_prompt_carries_absolute_incident_window() -> None:
    start, end = live_window(RECEIVED)
    assert start == RECEIVED - timedelta(minutes=10)
    assert end == RECEIVED + timedelta(minutes=1)
    prompt = build_prompt(_hook(), (start, end))
    assert "2026-11-09T17:32:05Z" in prompt
    assert "2026-11-09T17:43:05Z" in prompt
    # The timeline lookback is 72 h before the window's end, also absolute.
    assert "2026-11-06T17:43:05Z" in prompt
    assert "last few minutes" not in prompt


def test_prompt_names_the_app_and_runbook_sources() -> None:
    prompt = build_prompt(_hook(), live_window(RECEIVED))
    for needle in (
        "checkout",
        "AnalysisRun",
        "checkout_config_upstream_timeout_ms",
        "checkout-config",
        "example.dev/config-version",
        "a" * 40,
    ):
        assert needle in prompt, needle


def test_prompt_does_not_hand_over_the_answer() -> None:
    prompt = build_prompt(_hook(), live_window(RECEIVED))
    assert "2000" not in prompt
    assert "200 " not in prompt


def test_prompt_owner_labels_hint_optional() -> None:
    with_hint = build_prompt(_hook(), live_window(RECEIVED))
    without = build_prompt(_hook(), live_window(RECEIVED), owner_labels_hint=False)
    assert "slo.example.dev/success-rate" in with_hint
    assert "slo.example.dev/success-rate" not in without


def test_prompt_rejects_naive_window() -> None:
    with pytest.raises(ValueError):
        build_prompt(_hook(), (datetime(2026, 11, 9, 17, 0), datetime(2026, 11, 9, 17, 10)))
