"""The fix-PR outcome reconciler (Task 4.3a).

The App's webhook is inactive (GitHub cannot reach a laptop), so the bridge polls. Each pass
lists the agent's PRs and *sets* `aiops_fix_prs_total{outcome}` from the full listing, so a
restart never double counts. A merged PR is `merged` and a PR closed unmerged is `rejected`,
unless a label marks it as harness traffic (`demo-reset`: closed by `reset.sh` or run by an e2e or
rehearsal script; `policy-negative-test`), which counts as neither (O23).

Events (`change.merged`, `agent_action(rejected)`) go out once per PR per process. Every merge
emits `change.merged`, labelled or not, except one the act flow made and announced itself
(Task 5.4, through the shared IncidentRegistry); an excluded rejection emits nothing. The first
successful pass is a silent baseline: history already on the forge when the bridge starts is
counted, not announced again.

Policy results (Task 5.4) are counted here for both act paths, because when auto-merge is
enabled the act flow never sees the check conclude. Each pass reads `policy-check` on every
counted PR's head SHA and *sets* `aiops_policy_checks_total{result="pass"|"fail"}`, with the
same O23 exclusions. The first time an open PR's check has failed, it posts one comment and
emits `agent_action(policy_failed)`. Its own marker comment on the PR makes that once per PR,
across restarts too.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Callable
from datetime import UTC, datetime, timedelta

from . import events
from .events import Emitter
from .forge.base import POLICY_CHECK, CheckStatus, Forge, ForgeError, PullRequestInfo
from .incidents import IncidentRegistry
from .metrics import Metrics
from .pipeline import pr_sections

log = logging.getLogger("bridge.reconcile")

#: PRs carrying one of these labels are not fix-PR outcomes.
EXCLUDED_LABELS = frozenset({"demo-reset", "policy-negative-test"})


#: In the bridge's policy-failed comment, so a restarted bridge finds it and doesn't post again.
POLICY_FAILED_MARKER = "<!-- aiops:policy-failed -->"
#: A closed PR's check that is still missing or pending this long after the close never will be.
CHECK_SETTLE = timedelta(minutes=15)


def _excluded(pr: PullRequestInfo) -> bool:
    return bool(EXCLUDED_LABELS & set(pr.labels))


def _utcnow() -> datetime:
    return datetime.now(UTC)


def _closed_before(pr: PullRequestInfo, cutoff: datetime) -> bool:
    try:
        closed = datetime.fromisoformat(str(pr.closed_at))  # 3.11+ reads the trailing Z
    except ValueError:
        return False
    return closed.tzinfo is not None and closed < cutoff


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
        registry: IncidentRegistry | None = None,
        check_name: str = POLICY_CHECK,
        clock: Callable[[], datetime] = _utcnow,
    ) -> None:
        self.forge = forge
        self.metrics = metrics
        self.emitter = emitter
        self.app = app
        self.source = source
        self.repo = repo
        self.registry = registry
        self.check_name = check_name
        self.clock = clock
        self.seen: set[int] = set()
        self.baselined = False
        #: PRs whose policy-failed comment is known to be on GitHub.
        self.policy_commented: set[int] = set()
        #: Final check results of closed PRs, by head SHA: read once, not every pass.
        self._final_checks: dict[str, CheckStatus] = {}
        # Count from the start so the series exist (at 0) before the first listing succeeds.
        metrics.set_fix_prs("merged", 0)
        metrics.set_fix_prs("rejected", 0)
        metrics.set_policy_checks("pass", 0)
        metrics.set_policy_checks("fail", 0)

    async def run_once(self) -> None:
        """One pass. A forge error leaves the last values and the seen set alone."""
        try:
            prs = await self.forge.list_agent_prs(self.app, "all")
        except ForgeError as exc:
            log.warning("fix-PR reconcile failed: %s", type(exc).__name__)
            return
        merged = [p for p in prs if p.state == "closed" and p.merged]
        rejected = [p for p in prs if p.state == "closed" and not p.merged and not _excluded(p)]
        # O23: harness PRs count as neither outcome. The label usually lands just after the merge,
        # so a PR can be counted for a pass or two and then drop out; the gauge is set, not added to.
        self.metrics.set_fix_prs("merged", sum(1 for p in merged if not _excluded(p)))
        self.metrics.set_fix_prs("rejected", len(rejected))
        # change.merged goes out for every merge, labelled or not: the merge really landed on the
        # tracked branch, and the label's timing must not decide whether the timeline shows it.
        fresh = [(p, True) for p in merged if p.number not in self.seen]
        # A merge the act flow announced and then forgot (its own request lost the race to
        # GitHub's auto-merge) may have been skipped by an earlier pass as announced; report it now.
        released = self.registry.take_released() if self.registry is not None else set()
        fresh += [(p, True) for p in merged if p.number in self.seen and p.number in released]
        fresh += [(p, False) for p in rejected if p.number not in self.seen]
        self.seen.update(p.number for p, _ in fresh)
        if not self.baselined:
            self.baselined = True
        else:
            for pr, was_merged in sorted(fresh, key=lambda item: item[0].number):
                if was_merged and self.registry is not None and self.registry.merge_announced(pr.number):
                    continue  # the act flow merged it and emitted change.merged itself
                await self.emitter.emit(self._event(pr, was_merged))
        await self._policy(prs)

    async def _policy(self, prs: list[PullRequestInfo]) -> None:
        """Set the policy counts from every counted PR's check, then comment on new failures.
        A failed read leaves the last values: the counts are never set from a partial listing."""
        counted = [p for p in prs if not _excluded(p)]
        results: dict[int, CheckStatus] = {}
        try:
            for pr in counted:
                results[pr.number] = await self._check(pr)
        except ForgeError as exc:
            log.warning("policy-check reconcile failed: %s", type(exc).__name__)
            return
        self.metrics.set_policy_checks("pass", sum(1 for r in results.values() if r == "success"))
        self.metrics.set_policy_checks("fail", sum(1 for r in results.values() if r == "failure"))
        for pr in counted:
            if pr.state == "open" and results[pr.number] == "failure" and pr.number not in self.policy_commented:
                await self._policy_failed(pr)

    async def _check(self, pr: PullRequestInfo) -> CheckStatus:
        if pr.head_sha in self._final_checks:
            return self._final_checks[pr.head_sha]
        status = await self.forge.check_run_status(pr.head_sha, self.check_name)
        if pr.state == "closed" and (
            status in ("success", "failure") or _closed_before(pr, self.clock() - CHECK_SETTLE)
        ):
            self._final_checks[pr.head_sha] = status
        return status

    async def _policy_failed(self, pr: PullRequestInfo) -> None:
        """One comment per PR: skip when the bot's marker comment is already there."""
        try:
            if any(POLICY_FAILED_MARKER in body for body in await self.forge.list_pr_comments(pr.number)):
                self.policy_commented.add(pr.number)
                return
            text = f"{pr_sections()['policy']['failed']}\n\n{POLICY_FAILED_MARKER}\n"
            await self.forge.comment_on_pr(pr.number, text)
        except ForgeError as exc:
            log.warning("policy-failed comment on PR %s failed: %s", pr.number, type(exc).__name__)
            return  # retried on the next pass
        self.policy_commented.add(pr.number)
        self.metrics.action("policy_failed")
        try:
            await self.emitter.emit(
                events.agent_action("policy_failed", pr.url, "policy_check", source=self.source, app=self.app)
            )
        except Exception:  # a lost event never stops the reconciler
            log.warning("emitter failed for policy_failed on PR %s", pr.number, exc_info=True)

    def _event(self, pr: PullRequestInfo, merged: bool) -> dict:
        if merged:
            return events.change_merged(
                pr.url, pr.merge_sha or "", pr.merged_by or "unknown", source=self.source, repo=self.repo,
                app=self.app,
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
