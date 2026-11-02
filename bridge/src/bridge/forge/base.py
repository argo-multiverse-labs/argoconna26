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

    `open_pr` makes one commit on a new `agent/*` branch and opens the PR. Slice 4
    still adds `enable_auto_merge`, `merge_pr` and `check_run_status`.
    """

    async def read_file(self, path: str, ref: str) -> str: ...

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
    ) -> PullRequest: ...

    async def list_open_agent_prs(self, app: str) -> list[PullRequest]: ...

    async def list_agent_prs(self, app: str, state: Literal["open", "closed", "all"]) -> list[PullRequestInfo]: ...
