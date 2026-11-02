"""The fix-PR outcome reconciler (Task 4.3a).

The App's webhook is inactive (GitHub cannot reach a laptop), so the bridge polls. Each pass
lists the agent's PRs and *sets* `aiops_fix_prs_total{outcome}` from the full listing, so a
restart never double counts. A PR closed unmerged is `rejected`, unless a label marks it as
harness traffic (closed by `reset.sh`, or a policy negative test).

Events (`change.merged`, `agent_action(rejected)`) go out once per PR per process. The first
successful pass is a silent baseline: history already on the forge when the bridge starts is
counted, not announced again.
"""

from __future__ import annotations

import asyncio
import logging

from . import events
from .events import Emitter
from .forge.base import Forge, ForgeError, PullRequestInfo
from .metrics import Metrics

log = logging.getLogger("bridge.reconcile")

#: PRs carrying one of these labels are not fix-PR outcomes.
EXCLUDED_LABELS = frozenset({"demo-reset", "policy-negative-test"})


class Reconciler:
    def __init__(
        self,
        forge: Forge,
        metrics: Metrics,
        emitter: Emitter,
        *,
        app: str,
        source: str,
        repo: str | None = None,
    ) -> None:
        self.forge = forge
        self.metrics = metrics
        self.emitter = emitter
        self.app = app
        self.source = source
        self.repo = repo
        self.seen: set[int] = set()
        self.baselined = False
        # Count from the start so the series exist (at 0) before the first listing succeeds.
        metrics.set_fix_prs("merged", 0)
        metrics.set_fix_prs("rejected", 0)

    async def run_once(self) -> None:
        """One pass. A forge error leaves the last values and the seen set alone."""
        try:
            prs = await self.forge.list_agent_prs(self.app, "all")
        except ForgeError as exc:
            log.warning("fix-PR reconcile failed: %s", type(exc).__name__)
            return
        merged = [p for p in prs if p.state == "closed" and p.merged]
        rejected = [p for p in prs if p.state == "closed" and not p.merged and not EXCLUDED_LABELS & set(p.labels)]
        self.metrics.set_fix_prs("merged", len(merged))
        self.metrics.set_fix_prs("rejected", len(rejected))
        fresh = [(p, True) for p in merged if p.number not in self.seen]
        fresh += [(p, False) for p in rejected if p.number not in self.seen]
        self.seen.update(p.number for p, _ in fresh)
        if not self.baselined:
            self.baselined = True
            return
        for pr, was_merged in sorted(fresh, key=lambda item: item[0].number):
            await self.emitter.emit(self._event(pr, was_merged))

    def _event(self, pr: PullRequestInfo, merged: bool) -> dict:
        if merged:
            return events.change_merged(
                pr.url, pr.merge_sha or "", pr.merged_by or "unknown", source=self.source, repo=self.repo
            )
        return events.agent_action("rejected", pr.url, source=self.source, app=self.app)

    async def loop(self, interval_s: float) -> None:
        while True:
            try:
                await self.run_once()
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("fix-PR reconcile pass failed")
            await asyncio.sleep(interval_s)  # a fixed poll period, not a wait for a condition
