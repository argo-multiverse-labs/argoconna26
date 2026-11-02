"""An in-memory forge for tests."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

from .base import (
    AGENT_BRANCH_PREFIX,
    POLICY_CHECK,
    AutoMergeResult,
    CheckStatus,
    ForgeConflict,
    ForgeNotFound,
    MergeMethod,
    PullRequest,
    PullRequestInfo,
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
    base_sha: str | None = None


@dataclass
class FakeForge:
    """`files` maps (path, ref) to content. `commits` lists known full SHAs.

    `ancestors` maps a ref to the SHAs reachable from it. `changed_keys` maps
    (sha, path) to the keys that commit changed in that file. `prs` maps a SHA to
    PR numbers. `titles` maps a SHA to its commit title. Writes are recorded in `commit_comments` and `pr_comments`.
    Set `fail_reads` to an exception to make every read raise it, and `fail_writes`
    to make every comment raise it. `heads` maps a branch to its head SHA; a branch not
    in it resolves to its own name, so `files` keyed by branch name still read.

    Act (Task 5.4): `auto_merge` is what `enable_auto_merge` returns, or an exception it
    raises. `check_runs` maps a head SHA to the statuses `check_run_status` returns, one per
    call, the last one repeating (an exception in the list is raised); an unknown SHA is
    `missing`. Merges are recorded in `merged` as (number, method, head SHA), and `fail_merge`
    makes `merge_pr` raise. `pr_comments` doubles as the bot's comment listing.
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
    agent_prs: list[PullRequestInfo] = field(default_factory=list)
    opened: list[OpenedPR] = field(default_factory=list)
    calls: list[tuple] = field(default_factory=list)
    heads: dict[str, str] = field(default_factory=dict)
    auto_merge: AutoMergeResult | BaseException = "enabled"
    auto_merges: list[tuple[int, str]] = field(default_factory=list)
    check_runs: dict[str, list[CheckStatus | BaseException]] = field(default_factory=dict)
    merge_methods_allowed: tuple[MergeMethod, ...] = ("merge", "squash", "rebase")
    merged: list[tuple[int, str, str]] = field(default_factory=list)
    merge_shas: list[str] = field(default_factory=list)
    fail_merge: BaseException | None = None

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

    async def branch_head(self, branch: str) -> str:
        self._read("branch_head", branch)
        return self.heads.get(branch, branch)

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
        base_sha: str | None = None,
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
        pr = PullRequest(n, f"https://forge.test/pull/{n}", f"PR_{n}", f"{n:040x}", branch)
        self.opened.append(OpenedPR(base, branch, title, body, dict(changes), commit_message, pr, base_sha))
        return pr

    async def list_open_agent_prs(self, app: str | None = None) -> list[PullRequest]:
        self._read("list_open_agent_prs", app)
        prefix = f"{AGENT_BRANCH_PREFIX}{app}-" if app is not None else AGENT_BRANCH_PREFIX
        return [o.pr for o in self.opened if o.branch.startswith(prefix)]

    async def list_agent_prs(self, app: str, state: Literal["open", "closed", "all"]) -> list[PullRequestInfo]:
        self._read("list_agent_prs", app, state)
        prefix = f"{AGENT_BRANCH_PREFIX}{app}-"
        return [p for p in self.agent_prs if p.branch.startswith(prefix) and state in ("all", p.state)]

    async def list_pr_comments(self, number: int) -> list[str]:
        self._read("list_pr_comments", number)
        return [body for n, body in self.pr_comments if n == number]

    async def merge_methods(self) -> tuple[MergeMethod, ...]:
        self._read("merge_methods")
        return self.merge_methods_allowed

    async def enable_auto_merge(self, pr: PullRequest, method: MergeMethod) -> AutoMergeResult:
        self.calls.append(("enable_auto_merge", pr.number, method))
        if isinstance(self.auto_merge, BaseException):
            raise self.auto_merge
        self.auto_merges.append((pr.number, method))
        return self.auto_merge

    async def check_run_status(self, sha: str, name: str = POLICY_CHECK) -> CheckStatus:
        self._read("check_run_status", sha, name)
        queue = self.check_runs.get(sha)
        if not queue:
            return "missing"
        status = queue.pop(0) if len(queue) > 1 else queue[0]
        if isinstance(status, BaseException):
            raise status
        return status

    async def merge_pr(self, pr: PullRequest, method: MergeMethod) -> str:
        self.calls.append(("merge_pr", pr.number, method))
        if self.fail_merge is not None:
            raise self.fail_merge
        if self.fail_writes is not None:
            raise self.fail_writes
        sha = f"{pr.number + 5000:040x}"
        self.merged.append((pr.number, method, pr.head_sha))
        self.merge_shas.append(sha)
        return sha

    def info(self, number: int, *, state: str = "open", merged: bool = False, merged_by: str | None = None,
             labels: tuple[str, ...] = ()) -> PullRequestInfo:
        """A listing entry for a PR this forge opened, for tests that drive the reconciler."""
        pr = next(o.pr for o in self.opened if o.pr.number == number)
        merge_sha = self.merge_shas[0] if merged and self.merge_shas else None
        return PullRequestInfo(
            number=pr.number, url=pr.url, node_id=pr.node_id, head_sha=pr.head_sha, branch=pr.branch,
            state="open" if state == "open" else "closed", merged=merged, merged_by=merged_by,
            merge_sha=merge_sha, labels=labels,
        )
