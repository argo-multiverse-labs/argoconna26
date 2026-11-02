"""GitHub over REST, authenticated as the App installation."""

from __future__ import annotations

import base64
import re
from typing import Any, Literal, Protocol
from urllib.parse import quote

import httpx

from ..github_auth import GitHubAuthError
from .base import (
    AGENT_BRANCH_PREFIX,
    ForgeConflict,
    ForgeError,
    ForgeNotFound,
    PullRequest,
    PullRequestInfo,
    check_agent_branch,
)

# The App's login (demo.env BOT_LOGIN); list_open_agent_prs trusts only PRs it authored.
DEFAULT_BOT_LOGIN = "argoconna26-agent[bot]"
_HEX = re.compile(r"^[0-9a-f]{7,40}$")


class TokenProvider(Protocol):
    async def token(self) -> str: ...


class GitHubForge:
    def __init__(
        self,
        repo: str,
        token_provider: TokenProvider,
        *,
        api_url: str = "https://api.github.com",
        http: httpx.AsyncClient | None = None,
        timeout_s: float = 20.0,
        bot_login: str = DEFAULT_BOT_LOGIN,
    ) -> None:
        if repo.count("/") != 1:
            raise ValueError("repo must be owner/name")
        self.repo = repo
        self._tokens = token_provider
        self.bot_login = bot_login
        self._api = api_url.rstrip("/")
        self._http = http or httpx.AsyncClient(timeout=timeout_s)
        self._merged_by_cache: dict[int, str] = {}

    def __repr__(self) -> str:
        return f"GitHubForge(repo={self.repo!r})"

    async def _request(self, method: str, path: str, **kwargs: Any) -> httpx.Response:
        try:
            token = await self._tokens.token()
        except (GitHubAuthError, OSError) as exc:
            # A failed token exchange or an unreadable key is a forge error, so callers fail closed.
            raise ForgeError(f"{method} {path}: token unavailable ({type(exc).__name__})") from None
        headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        url = f"{self._api}/repos/{self.repo}{path}"
        try:
            response = await self._http.request(method, url, headers=headers, **kwargs)
        except httpx.HTTPError as exc:
            raise ForgeError(f"{method} {path}: {type(exc).__name__}") from None
        if response.status_code == 404:
            raise ForgeNotFound(f"{method} {path}: 404", 404)
        if response.status_code >= 400:
            raise ForgeError(f"{method} {path}: {response.status_code}", response.status_code)
        return response

    @staticmethod
    def _q(value: str) -> str:
        return quote(value, safe="/")

    async def read_file(self, path: str, ref: str) -> str:
        r = await self._request("GET", f"/contents/{self._q(path)}", params={"ref": ref})
        data = r.json()
        if not isinstance(data, dict) or data.get("encoding") != "base64":
            raise ForgeError(f"read_file {path}: not a file")
        return base64.b64decode(data.get("content", "")).decode("utf-8")

    async def resolve_sha(self, sha_or_prefix: str) -> str | None:
        prefix = sha_or_prefix.strip().lower()
        if not _HEX.match(prefix):
            return None
        try:
            r = await self._request("GET", f"/commits/{prefix}")
        except ForgeNotFound:
            return None
        except ForgeError as exc:
            if exc.status == 422:  # ambiguous or unknown prefix
                return None
            raise
        sha = str(r.json().get("sha", "")).lower()
        return sha if sha.startswith(prefix) and len(sha) == 40 else None

    async def is_ancestor(self, sha: str, ref: str) -> bool:
        try:
            r = await self._request("GET", f"/compare/{self._q(sha)}...{self._q(ref)}")
        except ForgeNotFound:
            return False
        return r.json().get("status") in ("ahead", "identical")

    async def commit_changed_key(self, sha: str, path: str, key: str) -> bool:
        try:
            r = await self._request("GET", f"/commits/{self._q(sha)}")
        except ForgeNotFound:
            return False
        changed = re.compile(rf"^[+-](?![+-])\s*['\"]?{re.escape(key)}['\"]?\s*:")
        for f in r.json().get("files", []):
            if f.get("filename") != path:
                continue
            return any(changed.match(line) for line in (f.get("patch") or "").splitlines())
        return False

    async def prs_for_commit(self, sha: str) -> list[int]:
        try:
            r = await self._request("GET", f"/commits/{self._q(sha)}/pulls")
        except ForgeNotFound:
            return []
        return [int(pr["number"]) for pr in r.json()]

    async def commit_title(self, sha: str) -> str | None:
        """The first line of the commit message, or None for an unknown commit."""
        try:
            r = await self._request("GET", f"/commits/{self._q(sha)}")
        except ForgeNotFound:
            return None
        message = str((r.json().get("commit") or {}).get("message") or "")
        return message.splitlines()[0].strip() if message.strip() else None

    async def comment_on_commit(self, sha: str, body: str) -> str:
        r = await self._request("POST", f"/commits/{self._q(sha)}/comments", json={"body": body})
        return str(r.json().get("html_url", ""))

    async def comment_on_pr(self, number: int, body: str) -> str:
        r = await self._request("POST", f"/issues/{int(number)}/comments", json={"body": body})
        return str(r.json().get("html_url", ""))

    async def open_pr(
        self,
        base: str,
        branch: str,
        title: str,
        body: str,
        changes: dict[str, str],
        commit_message: str,
    ) -> PullRequest:
        """One commit through the Git Data API on a new `agent/*` branch, then the PR.

        Blobs, then a tree on the base tree, then the commit, then the ref. A taken branch name
        raises ForgeConflict before any PR exists. If the PR call fails after the ref was made,
        the branch is deleted again so a retry can reuse the name.
        """
        check_agent_branch(branch)
        if not changes:
            raise ValueError("open_pr needs at least one entry in changes")
        ref = await self._request("GET", f"/git/ref/heads/{self._q(base)}")
        base_sha = str(ref.json()["object"]["sha"])
        base_commit = await self._request("GET", f"/git/commits/{base_sha}")
        base_tree = str(base_commit.json()["tree"]["sha"])
        entries = []
        for path, content in changes.items():
            blob = await self._request("POST", "/git/blobs", json={"content": content, "encoding": "utf-8"})
            entries.append({"path": path, "mode": "100644", "type": "blob", "sha": str(blob.json()["sha"])})
        tree = await self._request("POST", "/git/trees", json={"base_tree": base_tree, "tree": entries})
        commit = await self._request(
            "POST",
            "/git/commits",
            json={"message": commit_message, "tree": str(tree.json()["sha"]), "parents": [base_sha]},
        )
        commit_sha = str(commit.json()["sha"])
        try:
            await self._request("POST", "/git/refs", json={"ref": f"refs/heads/{branch}", "sha": commit_sha})
        except ForgeError as exc:
            if exc.status == 422:  # "Reference already exists"
                raise ForgeConflict(f"branch {branch} already exists", 422) from None
            raise
        try:
            r = await self._request("POST", "/pulls", json={"title": title, "head": branch, "base": base, "body": body})
        except ForgeError:
            try:
                await self._request("DELETE", f"/git/refs/heads/{self._q(branch)}")
            except ForgeError:
                pass  # best effort; the original failure is what the caller needs
            raise
        pr = r.json()
        return PullRequest(
            number=int(pr["number"]),
            url=str(pr.get("html_url", "")),
            node_id=str(pr.get("node_id", "")),
            head_sha=str((pr.get("head") or {}).get("sha", commit_sha)),
            branch=branch,
        )

    async def list_open_agent_prs(self, app: str | None = None) -> list[PullRequest]:
        """Open PRs from `agent/<app>-*` branches (any `agent/*` when `app` is None) whose author is the bot."""
        prefix = f"{AGENT_BRANCH_PREFIX}{app}-" if app is not None else AGENT_BRANCH_PREFIX
        found: list[PullRequest] = []
        page = 1
        while True:
            r = await self._request("GET", "/pulls", params={"state": "open", "per_page": 100, "page": page})
            batch = r.json()
            for pr in batch:
                head = pr.get("head") or {}
                if not str(head.get("ref", "")).startswith(prefix):
                    continue
                if (pr.get("user") or {}).get("login") != self.bot_login:
                    continue
                found.append(
                    PullRequest(
                        number=int(pr["number"]),
                        url=str(pr.get("html_url", "")),
                        node_id=str(pr.get("node_id", "")),
                        head_sha=str(head.get("sha", "")),
                        branch=str(head.get("ref", "")),
                    )
                )
            if len(batch) < 100:
                return found
            page += 1

    async def list_agent_prs(self, app: str, state: Literal["open", "closed", "all"]) -> list[PullRequestInfo]:
        """Agent PRs (bot author, `agent/<app>-*` branch) in the given state, newest first.

        The list endpoint does not say who merged, so a merged PR costs one extra GET, cached
        because a merged PR never changes. Reads at most 10 pages (1000 PRs).
        """
        prefix = f"{AGENT_BRANCH_PREFIX}{app}-"
        found: list[PullRequestInfo] = []
        for page in range(1, 11):
            r = await self._request("GET", "/pulls", params={"state": state, "per_page": 100, "page": page})
            batch = r.json()
            for pr in batch:
                head = pr.get("head") or {}
                if not str(head.get("ref", "")).startswith(prefix):
                    continue
                if (pr.get("user") or {}).get("login") != self.bot_login:
                    continue
                number = int(pr["number"])
                merged = bool(pr.get("merged_at"))
                found.append(
                    PullRequestInfo(
                        number=number,
                        url=str(pr.get("html_url", "")),
                        node_id=str(pr.get("node_id", "")),
                        head_sha=str(head.get("sha", "")),
                        branch=str(head.get("ref", "")),
                        state="open" if pr.get("state") == "open" else "closed",
                        merged=merged,
                        merged_by=await self._merged_by(number) if merged else None,
                        merge_sha=pr.get("merge_commit_sha"),
                        closed_at=pr.get("closed_at"),
                        labels=tuple(str(label.get("name", "")) for label in pr.get("labels") or []),
                    )
                )
            if len(batch) < 100:
                break
        return found

    async def _merged_by(self, number: int) -> str:
        if number in self._merged_by_cache:
            return self._merged_by_cache[number]
        r = await self._request("GET", f"/pulls/{number}")
        login = str((r.json().get("merged_by") or {}).get("login") or "unknown")
        self._merged_by_cache[number] = login
        return login
