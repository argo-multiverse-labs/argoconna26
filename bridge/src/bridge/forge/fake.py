"""An in-memory forge for tests."""

from __future__ import annotations

from dataclasses import dataclass, field

from .base import (
    AGENT_BRANCH_PREFIX,
    ForgeConflict,
    ForgeNotFound,
    PullRequest,
    check_agent_branch,
)


@dataclass
class OpenedPR:
    base: str
    branch: str
    title: str
    body: str
    changes: dict[str, str]
    commit_message: str
    pr: PullRequest


@dataclass
class FakeForge:
    """`files` maps (path, ref) to content. `commits` lists known full SHAs.

    `ancestors` maps a ref to the SHAs reachable from it. `changed_keys` maps
    (sha, path) to the keys that commit changed in that file. `prs` maps a SHA to
    PR numbers. `titles` maps a SHA to its commit title. Writes are recorded in `commit_comments` and `pr_comments`.
    Set `fail_reads` to an exception to make every read raise it, and `fail_writes`
    to make every comment raise it.
    """

    files: dict[tuple[str, str], str] = field(default_factory=dict)
    commits: list[str] = field(default_factory=list)
    ancestors: dict[str, set[str]] = field(default_factory=dict)
    changed_keys: dict[tuple[str, str], set[str]] = field(default_factory=dict)
    prs: dict[str, list[int]] = field(default_factory=dict)
    titles: dict[str, str] = field(default_factory=dict)
    fail_reads: BaseException | None = None
    fail_writes: BaseException | None = None
    commit_comments: list[tuple[str, str]] = field(default_factory=list)
    pr_comments: list[tuple[int, str]] = field(default_factory=list)
    opened: list[OpenedPR] = field(default_factory=list)
    calls: list[tuple] = field(default_factory=list)

    def _read(self, *call: object) -> None:
        self.calls.append(call)
        if self.fail_reads is not None:
            raise self.fail_reads

    async def read_file(self, path: str, ref: str) -> str:
        self._read("read_file", path, ref)
        try:
            return self.files[(path, ref)]
        except KeyError:
            raise ForgeNotFound(f"{path}@{ref}") from None

    async def resolve_sha(self, sha_or_prefix: str) -> str | None:
        self._read("resolve_sha", sha_or_prefix)
        prefix = sha_or_prefix.lower()
        matches = [s for s in self.commits if s.startswith(prefix)]
        return matches[0] if len(matches) == 1 else None

    async def is_ancestor(self, sha: str, ref: str) -> bool:
        self._read("is_ancestor", sha, ref)
        return sha == ref or sha in self.ancestors.get(ref, set())

    async def commit_changed_key(self, sha: str, path: str, key: str) -> bool:
        self._read("commit_changed_key", sha, path, key)
        return key in self.changed_keys.get((sha, path), set())

    async def prs_for_commit(self, sha: str) -> list[int]:
        self._read("prs_for_commit", sha)
        return list(self.prs.get(sha, []))

    async def commit_title(self, sha: str) -> str | None:
        self._read("commit_title", sha)
        return self.titles.get(sha)

    async def comment_on_commit(self, sha: str, body: str) -> str:
        self.calls.append(("comment_on_commit", sha))
        if self.fail_writes is not None:
            raise self.fail_writes
        self.commit_comments.append((sha, body))
        return f"https://forge.test/commit/{sha}#comment-{len(self.commit_comments)}"

    async def comment_on_pr(self, number: int, body: str) -> str:
        self.calls.append(("comment_on_pr", number))
        if self.fail_writes is not None:
            raise self.fail_writes
        self.pr_comments.append((number, body))
        return f"https://forge.test/pull/{number}#comment-{len(self.pr_comments)}"

    async def open_pr(
        self,
        base: str,
        branch: str,
        title: str,
        body: str,
        changes: dict[str, str],
        commit_message: str,
    ) -> PullRequest:
        self.calls.append(("open_pr", branch))
        check_agent_branch(branch)
        if not changes:
            raise ValueError("open_pr needs at least one entry in changes")
        if self.fail_writes is not None:
            raise self.fail_writes
        if any(o.branch == branch for o in self.opened):
            raise ForgeConflict(f"branch {branch} already exists", 422)
        n = len(self.opened) + 1
        pr = PullRequest(n, f"https://forge.test/pull/{n}", f"PR_{n}", f"{n:040x}")
        self.opened.append(OpenedPR(base, branch, title, body, dict(changes), commit_message, pr))
        return pr

    async def list_open_agent_prs(self, app: str) -> list[PullRequest]:
        self._read("list_open_agent_prs", app)
        prefix = f"{AGENT_BRANCH_PREFIX}{app}-"
        return [o.pr for o in self.opened if o.branch.startswith(prefix)]
