"""Task 6.5: `app-check` reads the App installation's permissions and proves a token mints.

Preflight's github-runtime section runs it. It must print permissions and the fact that a token
minted, and never the token or the JWT.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from bridge.cli import AppCheckError, run_app_check
from bridge.github_auth import InstallationTokenProvider

API = "https://api.github.test"
REPO = "example-org/example-repo"
INSTALLATION_ID = "987654"
INSTALLATION_URL = f"{API}/app/installations/{INSTALLATION_ID}"
TOKEN_URL = f"{INSTALLATION_URL}/access_tokens"
TOKEN = "installation-token-not-a-secret"


@pytest.fixture
def provider(tmp_path: Path) -> InstallationTokenProvider:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    path = tmp_path / "app-key"
    path.write_bytes(
        key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    )
    return InstallationTokenProvider("123456", INSTALLATION_ID, path, repo=REPO, api_url=API)


def _mint(router) -> None:
    exp = (datetime.now(UTC) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    router.post(TOKEN_URL).mock(return_value=httpx.Response(201, json={"token": TOKEN, "expires_at": exp}))


async def test_reports_permissions_and_a_minted_token(_no_unmocked_http, provider) -> None:
    r = _no_unmocked_http
    _mint(r)
    perms = {"contents": "write", "pull_requests": "write", "metadata": "read", "checks": "read"}
    route = r.get(INSTALLATION_URL).mock(return_value=httpx.Response(200, json={"permissions": perms}))
    async with httpx.AsyncClient() as http:
        provider._http = http
        res = await run_app_check(provider)
    assert res.token_minted is True
    assert res.permissions == perms
    # The installation is read with the App JWT, not the installation token.
    assert route.calls.last.request.headers["authorization"].startswith("Bearer ")
    assert TOKEN not in route.calls.last.request.headers["authorization"]
    assert TOKEN not in repr(res)


async def test_a_failed_mint_is_an_error_not_a_pass(_no_unmocked_http, provider) -> None:
    r = _no_unmocked_http
    r.post(TOKEN_URL).mock(return_value=httpx.Response(401, json={"message": "Bad credentials"}))
    r.get(INSTALLATION_URL).mock(return_value=httpx.Response(200, json={"permissions": {"contents": "write"}}))
    async with httpx.AsyncClient() as http:
        provider._http = http
        res = await run_app_check(provider)
    assert res.token_minted is False
    assert res.permissions == {"contents": "write"}


async def test_unreadable_installation_raises(_no_unmocked_http, provider) -> None:
    r = _no_unmocked_http
    _mint(r)
    r.get(INSTALLATION_URL).mock(return_value=httpx.Response(404, json={"message": "Not Found"}))
    async with httpx.AsyncClient() as http:
        provider._http = http
        with pytest.raises(AppCheckError, match="404"):
            await run_app_check(provider)


def test_main_prints_json_without_secrets(monkeypatch, capsys, _no_unmocked_http, tmp_path) -> None:
    from bridge.cli import main

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    path = tmp_path / "k"
    path.write_bytes(
        key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    )
    monkeypatch.setenv("GITHUB_APP_ID", "123456")
    monkeypatch.setenv("GITHUB_INSTALLATION_ID", INSTALLATION_ID)
    monkeypatch.setenv("GITHUB_APP_KEY_PATH", str(path))
    r = _no_unmocked_http
    exp = (datetime.now(UTC) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    r.post("https://api.github.com/app/installations/987654/access_tokens").mock(
        return_value=httpx.Response(201, json={"token": TOKEN, "expires_at": exp})
    )
    r.get("https://api.github.com/app/installations/987654").mock(
        return_value=httpx.Response(200, json={"permissions": {"contents": "write"}})
    )
    assert main(["app-check", "--repo", REPO]) == 0
    out = capsys.readouterr().out
    doc = json.loads(out)
    assert doc == {"token_minted": True, "permissions": {"contents": "write"}}
    assert TOKEN not in out
