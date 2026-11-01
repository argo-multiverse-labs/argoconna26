"""The trust metrics (spec 7.1): accuracy, guardrail executions, PII leaks caught, and actions.

Each `Metrics` owns its own registry, so tests never share counters.
"""

from __future__ import annotations

import json
import logging
import time
from collections.abc import Callable, Iterator, Mapping
from pathlib import Path
from typing import get_args

from prometheus_client import CollectorRegistry, Counter, Gauge, generate_latest
from prometheus_client.core import GaugeMetricFamily
from prometheus_client.registry import Collector

from .guardrails import Reason
from .pii import Kind

log = logging.getLogger("bridge.metrics")

LEVELS = ("suggest", "propose", "act")
ACTIONS = ("commented", "refused", "pii_blocked", "holmes_failed", "pr_opened", "auto_merge_enabled", "merged",
           "policy_failed", "post_failed")
DRYRUN_RELOAD_S = 60.0


class _DryrunAccuracy(Collector):
    """`aiops_dryrun_accuracy_ratio` = root_cause_matched / n from the harness's summary.json.

    The file comes from the optional ConfigMap `dryrun-summary`. It is re-read at most
    every `reload_s` seconds; with no file (or a bad one) the metric is absent, and the
    dashboard shows "pending".
    """

    def __init__(self, path: Path | None, reload_s: float, monotonic: Callable[[], float]) -> None:
        self.path = path
        self.reload_s = reload_s
        self._monotonic = monotonic
        self._loaded_at: float | None = None
        self._value: float | None = None

    def _read(self) -> float | None:
        if self.path is None:
            return None
        try:
            data = json.loads(self.path.read_text())
            n, matched = int(data["n"]), int(data["root_cause_matched"])
        except FileNotFoundError:
            return None
        except (OSError, ValueError, KeyError, TypeError) as exc:
            log.warning("dry-run summary unreadable: %s", type(exc).__name__)
            return None
        if n <= 0 or not 0 <= matched <= n:
            return None
        return matched / n

    def value(self) -> float | None:
        now = self._monotonic()
        if self._loaded_at is None or now - self._loaded_at >= self.reload_s:
            self._value = self._read()
            self._loaded_at = now
        return self._value

    def collect(self) -> Iterator[GaugeMetricFamily]:
        family = GaugeMetricFamily(
            "aiops_dryrun_accuracy_ratio", "Latest dry-run score: runs that matched the expected root cause / runs"
        )
        value = self.value()
        if value is not None:
            family.add_metric([], value)
        yield family


class Metrics:
    def __init__(
        self,
        registry: CollectorRegistry | None = None,
        *,
        dryrun_summary_path: str | Path | None = None,
        reload_s: float = DRYRUN_RELOAD_S,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self.registry = registry or CollectorRegistry()
        r = self.registry
        self.incidents = Counter("aiops_incidents_total", "Incidents handled, by autonomy level", ["level"], registry=r)
        self.guardrail_executions = Counter(
            "aiops_guardrail_executions_total", "Guardrail refusals, by reason", ["reason"], registry=r
        )
        self.policy_checks = Counter("aiops_policy_checks_total", "Policy check results", ["result"], registry=r)
        self.pii_leaks_caught = Counter(
            "aiops_pii_leaks_caught_total", "PII hits that blocked a post, by kind", ["kind"], registry=r
        )
        # Set (not counted) by the fix-PR outcome reconciler (Task 4.3a).
        self.fix_prs = Gauge("aiops_fix_prs_total", "Agent fix PRs, by outcome", ["outcome"], registry=r)
        self.human_touchpoints = Gauge(
            "aiops_human_touchpoints", "Steps a human must take at each autonomy level", ["level"], registry=r
        )
        self.actions = Counter("aiops_actions_total", "Bridge actions, by action", ["action"], registry=r)
        path = Path(dryrun_summary_path) if dryrun_summary_path else None
        self._dryrun = _DryrunAccuracy(path, reload_s, monotonic)
        r.register(self._dryrun)

        # Start the known series at 0, so the dashboard shows 0 rather than no data.
        for level in LEVELS:
            self.incidents.labels(level=level)
        for reason in get_args(Reason):
            self.guardrail_executions.labels(reason=reason)
        for kind in get_args(Kind):
            self.pii_leaks_caught.labels(kind=kind)
        for action in ACTIONS:
            self.actions.labels(action=action)

    def incident(self, level: str) -> None:
        self.incidents.labels(level=level).inc()

    def guardrail(self, reason: str) -> None:
        self.guardrail_executions.labels(reason=reason).inc()

    def pii_caught(self, kind: str) -> None:
        self.pii_leaks_caught.labels(kind=kind).inc()

    def action(self, action: str) -> None:
        self.actions.labels(action=action).inc()

    def set_touchpoints(self, touchpoints: Mapping[str, int]) -> None:
        for level, count in touchpoints.items():
            self.human_touchpoints.labels(level=level).set(count)

    def set_fix_prs(self, outcome: str, count: int) -> None:
        self.fix_prs.labels(outcome=outcome).set(count)

    def value(self, name: str, **labels: str) -> float | None:
        """One sample's current value, or None when the series doesn't exist."""
        return self.registry.get_sample_value(name, labels)

    def render(self) -> bytes:
        return generate_latest(self.registry)
