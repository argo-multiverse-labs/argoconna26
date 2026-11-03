"""DryForge: real reads, no writes. Used for checks that must never post to the public repo."""

from __future__ import annotations

import logging
from typing import Literal

from .. import stagelog
from .base import (
    POLICY_CHECK,
    AutoMergeResult,
    CheckStatus,
    Forge,
    MergeMethod,
    PullRequest,
    PullRequestInfo,
    check_agent_branch,
)

log = logging.getLogger("bridge.forge")


class DryForge:
    """Passes every read to `inner`; turns every write into a stage line and a log record."""

    def __init__(self, inner: Forge, cols: int | None = None) -> None:
        self.inner = inner
        self.cols = cols
        self.would: list[tuple[str, str]] = []

    def _skip(self, action: str, target: str) -> str:
        self.would.append((action, target))
        line = stagelog.emit("dry", f"would {action}", self.cols)
        log.info("%s (target %s; nothing sent)", line, target)
        return f"dry-run:{action}:{target}"

    async def read_file(self, path: str, ref: str) -> str:
        return await self.inner.read_file(path, ref)

    async def branch_head(self, branch: str) -> str:
        return await self.inner.branch_head(branch)

    async def resolve_sha(self, sha_or_prefix: str) -> str | None:
        return await self.inner.resolve_sha(sha_or_prefix)

    async def is_ancestor(self, sha: str, ref: str) -> bool:
        return await self.inner.is_ancestor(sha, ref)

    async def commit_changed_key(self, sha: str, path: str, key: str) -> bool:
        return await self.inner.commit_changed_key(sha, path, key)

    async def prs_for_commit(self, sha: str, merged_into: str | None = None) -> list[int]:
        return await self.inner.prs_for_commit(sha, merged_into)

    async def commit_title(self, sha: str) -> str | None:
        return await self.inner.commit_title(sha)

    async def comment_on_commit(self, sha: str, body: str) -> str:
        return self._skip("comment", f"commit {sha[:7]}")

    async def comment_on_pr(self, number: int, body: str) -> str:
        return self._skip("comment", f"pr {number}")

    async def open_pr(
        self,
        base: str,
        branch: str,
        title: str,
        body: str,
        changes: dict[str, str],
        commit_message: str,
        base_sha: str | None = None,
    ) -> PullRequest:
        check_agent_branch(branch)
        return PullRequest(0, self._skip("open pr", branch), "", "")

    async def list_open_agent_prs(self, app: str | None = None) -> list[PullRequest]:
        return await self.inner.list_open_agent_prs(app)

    async def list_agent_prs(self, app: str, state: Literal["open", "closed", "all"]) -> list[PullRequestInfo]:
        return await self.inner.list_agent_prs(app, state)

    async def list_pr_comments(self, number: int) -> list[str]:
        return await self.inner.list_pr_comments(number)

    async def merge_methods(self) -> tuple[MergeMethod, ...]:
        return await self.inner.merge_methods()

    async def check_run_status(self, sha: str, name: str = POLICY_CHECK) -> CheckStatus:
        return await self.inner.check_run_status(sha, name)

    async def enable_auto_merge(self, pr: PullRequest, method: MergeMethod) -> AutoMergeResult:
        # "enabled" ends the act flow here: a dry run never polls a check or merges.
        self._skip("enable auto-merge", f"pr {pr.number}")
        return "enabled"

    async def pr_merged(self, number: int) -> bool:
        return await self.inner.pr_merged(number)

    async def merge_pr(self, pr: PullRequest, method: MergeMethod) -> str:
        return self._skip("merge", f"pr {pr.number}")
