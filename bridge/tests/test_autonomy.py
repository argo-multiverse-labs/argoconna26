"""Task 3.5: the autonomy reader fails safe to `suggest`."""

from __future__ import annotations

from datetime import date

import pytest

from bridge.autonomy import Autonomy, read_autonomy
from bridge.forge import ForgeError
from bridge.forge.fake import FakeForge

PATH = "aiops/autonomy.yaml"
REF = "build/demo"

VALID = """\
apiVersion: aiops.example.dev/v1
kind: Autonomy
level: {level}
since: "2026-11-02"
promotion: null
touchpoints: {{suggest: 4, propose: 1, act: 1}}   # steps a human must take
"""


def forge_with(content: str) -> FakeForge:
    return FakeForge(files={(PATH, REF): content})


@pytest.mark.parametrize("level", ["suggest", "propose", "act"])
async def test_valid_levels_parse(level: str) -> None:
    autonomy, reason = await read_autonomy(forge_with(VALID.format(level=level)), REF)
    assert reason is None
    assert autonomy.level == level
    assert autonomy.since == date(2026, 11, 2)
    assert autonomy.promotion is None


async def test_missing_file_failsafe_suggest() -> None:
    autonomy, reason = await read_autonomy(FakeForge(), REF)
    assert autonomy.level == "suggest"
    assert reason is not None and "missing" in reason


async def test_unknown_level_failsafe_suggest() -> None:
    autonomy, reason = await read_autonomy(forge_with(VALID.format(level="yolo")), REF)
    assert autonomy.level == "suggest"
    assert reason is not None and "invalid" in reason


@pytest.mark.parametrize(
    "content",
    [
        "level: [unclosed",          # YAML syntax error
        "just a string",             # not a mapping
        "",                          # empty file
        "level: act\nsince: not-a-date\n",
    ],
)
async def test_parse_error_failsafe_suggest(content: str) -> None:
    autonomy, reason = await read_autonomy(forge_with(content), REF)
    assert autonomy.level == "suggest"
    assert reason


async def test_forge_error_failsafe_suggest() -> None:
    forge = FakeForge(fail_reads=ForgeError("github 502"))
    autonomy, reason = await read_autonomy(forge, REF)
    assert autonomy.level == "suggest"
    assert reason is not None and "forge error" in reason


async def test_unexpected_exception_failsafe_suggest() -> None:
    forge = FakeForge(fail_reads=RuntimeError("surprise"))
    autonomy, reason = await read_autonomy(forge, REF)
    assert autonomy.level == "suggest"
    assert reason


async def test_touchpoints_parsed() -> None:
    autonomy, _ = await read_autonomy(forge_with(VALID.format(level="propose")), REF)
    assert autonomy.touchpoints == {"suggest": 4, "propose": 1, "act": 1}


async def test_unknown_touchpoint_level_failsafe() -> None:
    content = VALID.format(level="act").replace("act: 1}", "act: 1, yolo: 0}")
    autonomy, reason = await read_autonomy(forge_with(content), REF)
    assert autonomy.level == "suggest"
    assert reason


async def test_promotion_record_parsed() -> None:
    content = """\
level: act
since: "2026-11-05"
promotion:
  from_level: propose
  dry_run_score: "20/20"
  approver_required: "@example-org/promotion-board"
  approved_by: admin-bypass
  pr: 42
touchpoints: {suggest: 4, propose: 1, act: 1}
"""
    autonomy, reason = await read_autonomy(forge_with(content), REF)
    assert reason is None
    assert autonomy.level == "act"
    assert autonomy.promotion is not None
    assert autonomy.promotion.from_level == "propose"
    assert autonomy.promotion.dry_run_score == "20/20"
    assert autonomy.promotion.approved_by == "admin-bypass"
    assert autonomy.promotion.pr == 42


async def test_failsafe_is_a_full_autonomy_object() -> None:
    autonomy, _ = await read_autonomy(FakeForge(), REF)
    assert isinstance(autonomy, Autonomy)
    assert autonomy.promotion is None
