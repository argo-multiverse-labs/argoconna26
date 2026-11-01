"""Task 3.9: the trust metrics (spec 7.1, Global Constraints metric names)."""

from __future__ import annotations

import json
from pathlib import Path

from bridge.metrics import Metrics

ALL_NAMES = {
    "aiops_incidents_total",
    "aiops_guardrail_executions_total",
    "aiops_policy_checks_total",
    "aiops_pii_leaks_caught_total",
    "aiops_fix_prs_total",
    "aiops_dryrun_accuracy_ratio",
    "aiops_human_touchpoints",
    "aiops_actions_total",
}


def _summary(path: Path, matched: int, n: int) -> Path:
    path.write_text(json.dumps({"n": n, "root_cause_matched": matched, "matched": matched - 1}))
    return path


def test_every_metric_is_declared(tmp_path: Path) -> None:
    m = Metrics(dryrun_summary_path=_summary(tmp_path / "summary.json", 17, 20))
    text = m.render().decode()
    for name in ALL_NAMES:
        assert f"# HELP {name.removesuffix('_total')}" in text, name


def test_guardrail_reasons_and_pii_kinds_start_at_zero() -> None:
    m = Metrics()
    assert m.value("aiops_guardrail_executions_total", reason="low_confidence") == 0
    assert m.value("aiops_pii_leaks_caught_total", kind="ipv4") == 0
    assert m.value("aiops_actions_total", action="commented") == 0


def test_counters_increment() -> None:
    m = Metrics()
    m.incident("suggest")
    m.guardrail("low_confidence")
    m.guardrail("low_confidence")
    m.pii_caught("email")
    m.action("refused")
    assert m.value("aiops_incidents_total", level="suggest") == 1
    assert m.value("aiops_guardrail_executions_total", reason="low_confidence") == 2
    assert m.value("aiops_pii_leaks_caught_total", kind="email") == 1
    assert m.value("aiops_actions_total", action="refused") == 1


def test_touchpoints_metric_from_autonomy() -> None:
    m = Metrics()
    m.set_touchpoints({"suggest": 4, "propose": 1, "act": 1})
    assert m.value("aiops_human_touchpoints", level="suggest") == 4
    assert m.value("aiops_human_touchpoints", level="act") == 1


def test_fix_prs_set_by_outcome() -> None:
    m = Metrics()
    assert m.value("aiops_fix_prs_total", outcome="merged") is None  # no outcomes until Task 4.3a
    m.set_fix_prs("merged", 3)
    assert m.value("aiops_fix_prs_total", outcome="merged") == 3


def test_dryrun_ratio_from_configmap_file(tmp_path: Path) -> None:
    m = Metrics(dryrun_summary_path=_summary(tmp_path / "summary.json", 17, 20))
    assert m.value("aiops_dryrun_accuracy_ratio") == 17 / 20


def test_dryrun_ratio_absent_when_file_missing(tmp_path: Path) -> None:
    m = Metrics(dryrun_summary_path=tmp_path / "nope.json")
    assert m.value("aiops_dryrun_accuracy_ratio") is None
    samples = [line for line in m.render().decode().splitlines() if not line.startswith("#")]
    assert not [line for line in samples if line.startswith("aiops_dryrun_accuracy_ratio")]


def test_dryrun_ratio_absent_when_file_bad(tmp_path: Path) -> None:
    for body in ("not json", json.dumps({"n": 0, "root_cause_matched": 0}), json.dumps({"n": 20})):
        path = tmp_path / "summary.json"
        path.write_text(body)
        assert Metrics(dryrun_summary_path=path).value("aiops_dryrun_accuracy_ratio") is None, body


def test_dryrun_ratio_reread_after_interval(tmp_path: Path) -> None:
    now = [1000.0]
    path = _summary(tmp_path / "summary.json", 10, 20)
    m = Metrics(dryrun_summary_path=path, reload_s=60, monotonic=lambda: now[0])
    assert m.value("aiops_dryrun_accuracy_ratio") == 0.5
    _summary(path, 20, 20)
    now[0] += 30
    assert m.value("aiops_dryrun_accuracy_ratio") == 0.5  # cached
    now[0] += 31
    assert m.value("aiops_dryrun_accuracy_ratio") == 1.0
    path.unlink()
    now[0] += 61
    assert m.value("aiops_dryrun_accuracy_ratio") is None


def test_instances_are_isolated() -> None:
    a, b = Metrics(), Metrics()
    a.action("commented")
    assert b.value("aiops_actions_total", action="commented") == 0
