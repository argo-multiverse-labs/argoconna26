"""GitHub App authentication: an RS256 app JWT, exchanged for a cached installation token.

Neither the JWT nor the installation token is ever logged or put in a repr.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import jwt

log = logging.getLogger("bridge.github_auth")

JWT_BACKDATE = timedelta(seconds=60)    # tolerate clock skew with GitHub
JWT_LIFETIME = timedelta(minutes=9)     # GitHub's maximum is 10
REFRESH_BEFORE = timedelta(minutes=5)

# Spec 7.6: contents and pull requests (write), checks (read). Requested on every
# token so it never carries more than this, whatever the installation allows.
TOKEN_PERMISSIONS = {"contents": "write", "pull_requests": "write", "checks": "read"}


class GitHubAuthError(Exception):
    pass


def _utcnow() -> datetime:
    return datetime.now(UTC)


class InstallationTokenProvider:
    def __init__(
        self,
        app_id: str,
        installation_id: str,
        key_path: str | Path,
        *,
        repo: str,
        api_url: str = "https://api.github.com",
        clock: Callable[[], datetime] = _utcnow,
        http: httpx.AsyncClient | None = None,
    ) -> None:
        self.app_id = str(app_id)
        self.installation_id = str(installation_id)
        self.key_path = Path(key_path)
        owner, _, name = repo.partition("/")
        if not owner or not name or "/" in name:
            raise ValueError("repo must be owner/name")
        self.repo_name = name
        self._api = api_url.rstrip("/")
        self._clock = clock
        self._http = http or httpx.AsyncClient(timeout=20.0)
        self._token: str | None = None
        self._expires_at: datetime | None = None
        self._lock = asyncio.Lock()

    def __repr__(self) -> str:
        return f"InstallationTokenProvider(app_id={self.app_id!r}, installation_id={self.installation_id!r})"

    def app_jwt(self) -> str:
        now = self._clock()
        iat = now - JWT_BACKDATE
        claims = {
            "iat": int(iat.timestamp()),
            "exp": int((now + JWT_LIFETIME).timestamp()),  # exp - iat = 600 s
            "iss": self.app_id,
        }
        return jwt.encode(claims, self.key_path.read_bytes(), algorithm="RS256")

    def _fresh(self) -> bool:
        return (
            self._token is not None
            and self._expires_at is not None
            and self._clock() < self._expires_at - REFRESH_BEFORE
        )

    async def token(self) -> str:
        if self._fresh():
            return self._token  # type: ignore[return-value]
        async with self._lock:
            if self._fresh():
                return self._token  # type: ignore[return-value]
            url = f"{self._api}/app/installations/{self.installation_id}/access_tokens"
            try:
                r = await self._http.post(
                    url,
                    headers={
                        "Authorization": f"Bearer {self.app_jwt()}",
                        "Accept": "application/vnd.github+json",
                        "X-GitHub-Api-Version": "2022-11-28",
                    },
                    json={"repositories": [self.repo_name], "permissions": TOKEN_PERMISSIONS},
                )
            except httpx.HTTPError as exc:
                raise GitHubAuthError(f"installation token request failed: {type(exc).__name__}") from None
            if r.status_code != 201:
                raise GitHubAuthError(f"installation token request returned {r.status_code}")
            data = r.json()
            self._token = str(data["token"])
            self._expires_at = datetime.fromisoformat(str(data["expires_at"]))
            log.info("installation token minted; expires %s", self._expires_at.isoformat())
            return self._token
