"""GitHub over REST, authenticated as the App installation."""

from __future__ import annotations

import base64
import re
from typing import Any, Protocol
from urllib.parse import quote

import httpx

from .base import ForgeError, ForgeNotFound

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
    ) -> None:
        if repo.count("/") != 1:
            raise ValueError("repo must be owner/name")
        self.repo = repo
        self._tokens = token_provider
        self._api = api_url.rstrip("/")
        self._http = http or httpx.AsyncClient(timeout=timeout_s)

    def __repr__(self) -> str:
        return f"GitHubForge(repo={self.repo!r})"

    async def _request(self, method: str, path: str, **kwargs: Any) -> httpx.Response:
        headers = {
            "Authorization": f"Bearer {await self._tokens.token()}",
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

    async def comment_on_commit(self, sha: str, body: str) -> str:
        r = await self._request("POST", f"/commits/{self._q(sha)}/comments", json={"body": body})
        return str(r.json().get("html_url", ""))

    async def comment_on_pr(self, number: int, body: str) -> str:
        r = await self._request("POST", f"/issues/{int(number)}/comments", json={"body": body})
        return str(r.json().get("html_url", ""))
