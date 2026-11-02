"""The forge interface. GitHub is the one real implementation; any forge fits."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Protocol, runtime_checkable


class ForgeError(Exception):
    """A forge call failed (network, auth, 5xx, unexpected response)."""

    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


class ForgeNotFound(ForgeError):
    """The file, commit or ref does not exist."""


class ForgeConflict(ForgeError):
    """The write collides with something that exists (for example the branch name is taken)."""


@dataclass(frozen=True)
class PullRequest:
    number: int
    url: str
    node_id: str
    head_sha: str
    #: The head branch (`agent/<app>-<cause7>-<revision7>` for a fix PR); "" when unknown.
    branch: str = ""


@dataclass(frozen=True)
class PullRequestInfo:
    """One agent PR as the outcome reconciler sees it (Task 4.3a)."""

    number: int
    url: str
    node_id: str
    head_sha: str
    branch: str
    state: Literal["open", "closed"]
    merged: bool = False
    merged_by: str | None = None
    merge_sha: str | None = None
    closed_at: str | None = None
    labels: tuple[str, ...] = ()


MergeMethod = Literal["merge", "squash", "rebase"]
#: `clean_status`: GitHub refused auto-merge because the PR can be merged right now (no required
#: check holds it), so the caller has to wait for the check itself (Task 5.4).
AutoMergeResult = Literal["enabled", "clean_status"]
CheckStatus = Literal["pending", "success", "failure", "missing"]
#: The required check's name (demo.env POLICY_CHECK_CONTEXT).
POLICY_CHECK = "policy-check"

#: Every branch the bridge creates starts with this, and every guard keys on it.
AGENT_BRANCH_PREFIX = "agent/"


def check_agent_branch(branch: str) -> None:
    """Refuse any branch name outside `agent/<name>`, before a single call is made."""
    name = branch[len(AGENT_BRANCH_PREFIX) :] if branch.startswith(AGENT_BRANCH_PREFIX) else ""
    if not name or ".." in branch:
        raise ValueError(f"the bridge only opens PRs from {AGENT_BRANCH_PREFIX}<name> branches, not {branch!r}")


@runtime_checkable
class Forge(Protocol):
    """Every Git and forge call the bridge makes. Reads first, then writes.

    `open_pr` makes one commit on a new `agent/*` branch and opens the PR. At `act`,
    `enable_auto_merge` hands the merge to GitHub, and `merge_pr` is the bridge's own merge on
    the `clean_status` fallback, called only after `check_run_status` returned `success`.
    """

    async def read_file(self, path: str, ref: str) -> str: ...

    async def branch_head(self, branch: str) -> str:
        """The full SHA a branch points at now."""
        ...

    async def resolve_sha(self, sha_or_prefix: str) -> str | None: ...

    async def is_ancestor(self, sha: str, ref: str) -> bool: ...

    async def commit_changed_key(self, sha: str, path: str, key: str) -> bool: ...

    async def prs_for_commit(self, sha: str) -> list[int]: ...

    async def commit_title(self, sha: str) -> str | None: ...

    async def comment_on_commit(self, sha: str, body: str) -> str: ...

    async def comment_on_pr(self, number: int, body: str) -> str: ...

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
        """`base_sha`, when given, is the commit's parent (the SHA the changed files were read
        at); otherwise the base branch's current head."""
        ...

    async def list_open_agent_prs(self, app: str | None = None) -> list[PullRequest]:
        """Open bot PRs from `agent/<app>-*` branches, or from any `agent/*` branch when `app` is None."""
        ...

    async def list_agent_prs(self, app: str, state: Literal["open", "closed", "all"]) -> list[PullRequestInfo]: ...

    async def list_pr_comments(self, number: int) -> list[str]:
        """The bodies of the bot's own comments on a PR (other authors' are left out)."""
        ...

    async def merge_methods(self) -> tuple[MergeMethod, ...]:
        """The merge methods the repository allows, in the order merge, squash, rebase."""
        ...

    async def enable_auto_merge(self, pr: PullRequest, method: MergeMethod) -> AutoMergeResult: ...

    async def check_run_status(self, sha: str, name: str = POLICY_CHECK) -> CheckStatus: ...

    async def merge_pr(self, pr: PullRequest, method: MergeMethod) -> str:
        """Merge `pr` at its recorded head SHA (a moved head is refused); returns the merge SHA."""
        ...
