"""The forge interface. GitHub is the one real implementation; any forge fits."""

from __future__ import annotations

from typing import Protocol, runtime_checkable


class ForgeError(Exception):
    """A forge call failed (network, auth, 5xx, unexpected response)."""

    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


class ForgeNotFound(ForgeError):
    """The file, commit or ref does not exist."""


@runtime_checkable
class Forge(Protocol):
    """Every Git and forge call the bridge makes. Reads first, then writes.

    Slice 4 adds `open_pr`, `list_open_agent_prs`, `enable_auto_merge`,
    `merge_pr` and `check_run_status`.
    """

    async def read_file(self, path: str, ref: str) -> str: ...

    async def resolve_sha(self, sha_or_prefix: str) -> str | None: ...

    async def is_ancestor(self, sha: str, ref: str) -> bool: ...

    async def commit_changed_key(self, sha: str, path: str, key: str) -> bool: ...

    async def prs_for_commit(self, sha: str) -> list[int]: ...

    async def commit_title(self, sha: str) -> str | None: ...

    async def comment_on_commit(self, sha: str, body: str) -> str: ...

    async def comment_on_pr(self, number: int, body: str) -> str: ...
