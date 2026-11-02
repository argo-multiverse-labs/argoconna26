"""Task 3.7: guardrails normalize the model's output, refuse a wrong cause, and never refuse a correct one."""

from __future__ import annotations

import httpx
import pytest

from bridge.config import Settings
from bridge.forge import ForgeError
from bridge.forge.fake import FakeForge
from bridge.forge.github import GitHubForge
from bridge.github_auth import GitHubAuthError
from bridge.guardrails import Refusal, evaluate
from bridge.models import ArgoDegradedHook
from bridge.rca import RCA

from .conftest import hook_body

SYNCED = "5d0c9f2a7b3e41c8a9e0f6d2b1c4a7e8f9d0c3b2"
PREVIOUS = "8e1f3a5c7b9d0e2f4a6c8b0d1e3f5a7c9b1d3e5f"
OLD_CAUSE = "3a7c1e9b5d2f4a6c8e0b1d3f5a7c9e2b4d6f8a0c"  # not in Argo history; an ancestor
UNRELATED = "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432"  # an ancestor that didn't touch the key
PATH = "apps/checkout/config/checkout-config.yaml"
KEY = "UPSTREAM_TIMEOUT_MS"
BRANCH = "build/demo"

CONFIGMAP = """\
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-config
data:
  UPSTREAM_TIMEOUT_MS: {value}
  LOG_LEVEL: info
"""


def make_hook() -> ArgoDegradedHook:
    return ArgoDegradedHook.model_validate(
        hook_body(
            revision=SYNCED,
            sync_revision=SYNCED,
            history=[
                {"id": 1, "revision": PREVIOUS, "deployedAt": "2026-11-01T10:00:00Z"},
                {"id": 2, "revision": SYNCED, "deployedAt": "2026-11-02T10:00:00Z"},
            ],
        )
    )


def make_forge(value: str = '"200"') -> FakeForge:
    return FakeForge(
        files={(PATH, BRANCH): CONFIGMAP.format(value=value)},
        commits=[SYNCED, PREVIOUS, OLD_CAUSE, UNRELATED],
        ancestors={SYNCED: {PREVIOUS, OLD_CAUSE, UNRELATED}},
        changed_keys={(OLD_CAUSE, PATH): {KEY}, (UNRELATED, PATH): {"LOG_LEVEL"}},
    )


def make_rca(**overrides: object) -> RCA:
    data: dict = {
        "root_cause": "The canary ran with a 200 ms upstream timeout.",
        "cause_commit_sha": PREVIOUS,
        "evidence": ["Prometheus: canary pods report 200"],
        "delivery_context": "Timeline: CHG-ab12cd merged 3 days earlier",
        "confidence": 0.9,
        "proposed_patch": {"file": PATH, "key": KEY, "from": "200", "to": "2000"},
    }
    patch = overrides.pop("patch", None)
    data.update(overrides)
    if patch:
        data["proposed_patch"] = {**data["proposed_patch"], **patch}
    return RCA.model_validate(data)


@pytest.fixture
def settings_() -> Settings:
    return Settings(tracked_branch=BRANCH, confidence_threshold=0.7)


def reasons(refusals: list[Refusal]) -> list[str]:
    return [r.reason for r in refusals]


async def test_correct_rca_passes(settings_: Settings) -> None:
    rca, refusals = await evaluate(make_rca(), make_hook(), make_forge(), settings_)
    assert refusals == []
    assert rca.cause_commit_sha == PREVIOUS


async def test_low_confidence_refused(settings_: Settings) -> None:
    _, refusals = await evaluate(make_rca(confidence=0.69), make_hook(), make_forge(), settings_)
    assert reasons(refusals) == ["low_confidence"]


async def test_threshold_equal_passes(settings_: Settings) -> None:
    _, refusals = await evaluate(make_rca(confidence=0.7), make_hook(), make_forge(), settings_)
    assert refusals == []


async def test_sha_in_history_passes(settings_: Settings) -> None:
    forge = make_forge()
    _, refusals = await evaluate(make_rca(cause_commit_sha=SYNCED), make_hook(), forge, settings_)
    assert refusals == []
    # In history, so no ancestry lookup was needed.
    assert not [c for c in forge.calls if c[0] == "is_ancestor"]


async def test_sha_ancestor_touching_key_passes(settings_: Settings) -> None:
    rca, refusals = await evaluate(make_rca(cause_commit_sha=OLD_CAUSE), make_hook(), make_forge(), settings_)
    assert refusals == []
    assert rca.cause_commit_sha == OLD_CAUSE


async def test_sha_ancestor_not_touching_key_refused(settings_: Settings) -> None:
    _, refusals = await evaluate(make_rca(cause_commit_sha=UNRELATED), make_hook(), make_forge(), settings_)
    assert reasons(refusals) == ["cause_not_in_history"]


async def test_unknown_sha_refused(settings_: Settings) -> None:
    _, refusals = await evaluate(make_rca(cause_commit_sha="0" * 40), make_hook(), make_forge(), settings_)
    assert reasons(refusals) == ["cause_not_in_history"]


async def test_non_hex_sha_refused(settings_: Settings) -> None:
    _, refusals = await evaluate(make_rca(cause_commit_sha="HEAD~1"), make_hook(), make_forge(), settings_)
    assert reasons(refusals) == ["cause_not_in_history"]


async def test_short_sha_resolved(settings_: Settings) -> None:
    # A 7-character prefix of a history revision, and one of an older ancestor.
    rca, refusals = await evaluate(make_rca(cause_commit_sha=PREVIOUS[:7]), make_hook(), make_forge(), settings_)
    assert refusals == []
    assert rca.cause_commit_sha == PREVIOUS
    rca, refusals = await evaluate(make_rca(cause_commit_sha=OLD_CAUSE[:7]), make_hook(), make_forge(), settings_)
    assert refusals == []
    assert rca.cause_commit_sha == OLD_CAUSE


async def test_uppercase_sha_normalized(settings_: Settings) -> None:
    rca, refusals = await evaluate(
        make_rca(cause_commit_sha=f"  {PREVIOUS.upper()} "), make_hook(), make_forge(), settings_
    )
    assert refusals == []
    assert rca.cause_commit_sha == PREVIOUS


async def test_leading_dot_slash_path(settings_: Settings) -> None:
    for path in (f"./{PATH}", f"/{PATH}", f" ./{PATH} "):
        rca, refusals = await evaluate(make_rca(patch={"file": path}), make_hook(), make_forge(), settings_)
        assert refusals == [], path
        assert rca.proposed_patch.file == PATH


@pytest.mark.parametrize(
    "path",
    [
        "apps/checkout/deploy/rollout.yaml",
        "apps/checkout/config/sub/checkout-config.yaml",
        "apps/../policy/config/x.yaml",
        "apps/checkout/config/../deploy/rollout.yaml",
        "policy/data/agent.yaml",
        "apps/checkout/config/checkout-config.json",
    ],
)
async def test_file_outside_allowlist_refused(settings_: Settings, path: str) -> None:
    forge = make_forge()
    _, refusals = await evaluate(make_rca(patch={"file": path}), make_hook(), forge, settings_)
    assert "file_not_allowed" in reasons(refusals)
    # A disallowed file is never read.
    assert not [c for c in forge.calls if c[0] == "read_file"]


async def test_from_mismatch_refused(settings_: Settings) -> None:
    _, refusals = await evaluate(make_rca(), make_hook(), make_forge(value='"2000"'), settings_)
    assert reasons(refusals) == ["from_mismatch"]


@pytest.mark.parametrize("file_value", ['"200"', "200", "'200'"])
@pytest.mark.parametrize("model_from", ["200", '"200"', "'200'", " 200 "])
async def test_quoted_and_unquoted_values_equal(settings_: Settings, file_value: str, model_from: str) -> None:
    rca, refusals = await evaluate(
        make_rca(patch={"from": model_from, "to": '"2000"'}), make_hook(), make_forge(value=file_value), settings_
    )
    assert refusals == []
    assert rca.proposed_patch.from_value == "200"
    assert rca.proposed_patch.to_value == "2000"


async def test_key_not_found_refused(settings_: Settings) -> None:
    _, refusals = await evaluate(make_rca(patch={"key": "NO_SUCH_KEY"}), make_hook(), make_forge(), settings_)
    assert reasons(refusals) == ["key_not_found"]


async def test_missing_file_refused_as_key_not_found(settings_: Settings) -> None:
    path = "apps/checkout/config/other.yaml"
    _, refusals = await evaluate(make_rca(patch={"file": path}), make_hook(), make_forge(), settings_)
    assert reasons(refusals) == ["key_not_found"]


async def test_multiple_refusals_all_reported(settings_: Settings) -> None:
    rca = make_rca(
        confidence=0.2,
        cause_commit_sha="0" * 40,
        patch={"file": "apps/checkout/deploy/rollout.yaml"},
    )
    _, refusals = await evaluate(rca, make_hook(), make_forge(), settings_)
    assert sorted(reasons(refusals)) == ["cause_not_in_history", "file_not_allowed", "low_confidence"]
    assert all(r.detail for r in refusals)


async def test_forge_error_fails_closed(settings_: Settings) -> None:
    forge = make_forge()
    forge.fail_reads = ForgeError("github 502")
    _, refusals = await evaluate(make_rca(cause_commit_sha=OLD_CAUSE), make_hook(), forge, settings_)
    assert set(reasons(refusals)) == {"cause_not_in_history", "key_not_found"}


async def test_reads_the_tracked_branch(settings_: Settings) -> None:
    forge = make_forge()
    await evaluate(make_rca(), make_hook(), forge, settings_)
    assert ("read_file", PATH, BRANCH) in forge.calls


@pytest.mark.parametrize("key", ["kind", "apiVersion", "metadata"])
async def test_top_level_field_refused(settings_: Settings, key: str) -> None:
    """Only ConfigMap `data` keys are config values; the object's own fields never are."""
    rca = make_rca(patch={"key": key, "from": "ConfigMap", "to": "Secret"})
    _, refusals = await evaluate(rca, make_hook(), make_forge(), settings_)
    assert reasons(refusals) == ["key_not_found"]


async def test_key_outside_configmap_refused(settings_: Settings) -> None:
    """A `data` map on a kind other than ConfigMap is not a config value either."""
    text = "apiVersion: v1\nkind: Secret\nmetadata:\n  name: x\ndata:\n  UPSTREAM_TIMEOUT_MS: '200'\n"
    forge = FakeForge(
        files={(PATH, BRANCH): text},
        commits=[SYNCED, PREVIOUS],
        ancestors={SYNCED: {PREVIOUS}},
    )
    _, refusals = await evaluate(make_rca(), make_hook(), forge, settings_)
    assert reasons(refusals) == ["key_not_found"]


def test_threshold_above_one_accepted(monkeypatch: pytest.MonkeyPatch) -> None:
    """Task 4.6's forced-refusal path sets the threshold above 1; Settings must accept it."""
    monkeypatch.setenv("CONFIDENCE_THRESHOLD", "1.01")
    assert Settings().confidence_threshold == pytest.approx(1.01)


async def test_threshold_above_one_refuses_full_confidence() -> None:
    settings = Settings(tracked_branch=BRANCH, confidence_threshold=1.01)
    _, refusals = await evaluate(make_rca(confidence=1.0), make_hook(), make_forge(), settings)
    assert reasons(refusals) == ["low_confidence"]


def test_negative_threshold_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CONFIDENCE_THRESHOLD", "-0.1")
    with pytest.raises(ValueError):
        Settings()


class _FailingTokens:
    def __init__(self, exc: Exception) -> None:
        self.exc = exc

    async def token(self) -> str:
        raise self.exc


@pytest.mark.parametrize(
    "exc",
    [GitHubAuthError("installation token request returned 401"), FileNotFoundError("app-key")],
)
async def test_token_failure_fails_closed(settings_: Settings, exc: Exception) -> None:
    """A failed token exchange or a missing key file is a forge error: refuse, don't raise."""
    async with httpx.AsyncClient() as http:
        forge = GitHubForge("example-org/example-repo", _FailingTokens(exc), api_url="https://api.github.test", http=http)
        _, refusals = await evaluate(make_rca(cause_commit_sha=OLD_CAUSE), make_hook(), forge, settings_)
    assert set(reasons(refusals)) == {"cause_not_in_history", "key_not_found"}


def test_test_holmes_timeout_overrides_deployment_value(monkeypatch: pytest.MonkeyPatch) -> None:
    """A Deployment env entry beats envFrom, so the Task 4.6 timeout hook uses its own name."""
    monkeypatch.setenv("HOLMES_TIMEOUT_S", "115")
    monkeypatch.setenv("TEST_HOLMES_TIMEOUT_S", "1")
    assert Settings().holmes_timeout_s == 1
    monkeypatch.delenv("TEST_HOLMES_TIMEOUT_S")
    assert Settings().holmes_timeout_s == 115
