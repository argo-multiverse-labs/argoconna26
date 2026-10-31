"""Task 3.5: GitHub App JWT and the cached installation token."""

from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import jwt
import pytest
import respx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from bridge.github_auth import InstallationTokenProvider

API = "https://api.github.test"
APP_ID = "123456"
INSTALLATION_ID = "987654"
TOKEN_URL = f"{API}/app/installations/{INSTALLATION_ID}/access_tokens"


@pytest.fixture
def keypair(tmp_path: Path) -> tuple[Path, rsa.RSAPublicKey]:
    """A throwaway RSA key written to tmp_path at test time; nothing is committed."""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    path = tmp_path / "app-key"
    path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    return path, key.public_key()


class Clock:
    def __init__(self, now: datetime) -> None:
        self.now = now

    def __call__(self) -> datetime:
        return self.now


def token_response(token: str, expires_at: datetime) -> httpx.Response:
    return httpx.Response(
        201, json={"token": token, "expires_at": expires_at.strftime("%Y-%m-%dT%H:%M:%SZ")}
    )


def test_jwt_claims_and_expiry(keypair) -> None:
    key_path, public_key = keypair
    clock = Clock(datetime(2026, 11, 2, 9, 0, tzinfo=UTC))
    provider = InstallationTokenProvider(APP_ID, INSTALLATION_ID, key_path, api_url=API, clock=clock)
    encoded = provider.app_jwt()
    header = jwt.get_unverified_header(encoded)
    assert header["alg"] == "RS256"
    claims = jwt.decode(encoded, public_key, algorithms=["RS256"], options={"verify_exp": False, "verify_iat": False})
    assert claims["iss"] == APP_ID
    assert claims["exp"] - claims["iat"] <= 600
    assert claims["exp"] > int(clock.now.timestamp())
    assert claims["iat"] <= int(clock.now.timestamp())


@respx.mock(assert_all_mocked=True)
async def test_installation_token_cached_and_refreshed(respx_mock, keypair) -> None:
    key_path, public_key = keypair
    t0 = datetime(2026, 11, 2, 9, 0, tzinfo=UTC)
    clock = Clock(t0)
    route = respx_mock.post(TOKEN_URL).mock(
        side_effect=[
            token_response("inst-token-one", t0 + timedelta(hours=1)),
            token_response("inst-token-two", t0 + timedelta(hours=2)),
        ]
    )
    async with httpx.AsyncClient() as http:
        provider = InstallationTokenProvider(
            APP_ID, INSTALLATION_ID, key_path, api_url=API, clock=clock, http=http
        )
        assert await provider.token() == "inst-token-one"
        # Cached: 54 minutes later is still more than 5 minutes before expiry.
        clock.now = t0 + timedelta(minutes=54)
        assert await provider.token() == "inst-token-one"
        assert route.call_count == 1
        # Inside the 5-minute refresh window: a new token is minted.
        clock.now = t0 + timedelta(minutes=55, seconds=1)
        assert await provider.token() == "inst-token-two"
        assert route.call_count == 2

    request = route.calls[0].request
    bearer = request.headers["Authorization"].removeprefix("Bearer ")
    claims = jwt.decode(bearer, public_key, algorithms=["RS256"], options={"verify_exp": False, "verify_iat": False})
    assert claims["iss"] == APP_ID


@respx.mock(assert_all_mocked=True)
async def test_installation_token_error_raises_without_token(respx_mock, keypair) -> None:
    key_path, _ = keypair
    respx_mock.post(TOKEN_URL).mock(return_value=httpx.Response(401, json={"message": "Bad credentials"}))
    async with httpx.AsyncClient() as http:
        provider = InstallationTokenProvider(APP_ID, INSTALLATION_ID, key_path, api_url=API, http=http)
        with pytest.raises(Exception) as excinfo:
            await provider.token()
    assert "401" in str(excinfo.value)


@respx.mock(assert_all_mocked=True)
async def test_token_never_logged(respx_mock, keypair, caplog: pytest.LogCaptureFixture) -> None:
    key_path, _ = keypair
    t0 = datetime(2026, 11, 2, 9, 0, tzinfo=UTC)
    respx_mock.post(TOKEN_URL).mock(return_value=token_response("inst-token-secret-value", t0 + timedelta(hours=1)))
    caplog.set_level(logging.DEBUG)
    async with httpx.AsyncClient() as http:
        provider = InstallationTokenProvider(
            APP_ID, INSTALLATION_ID, key_path, api_url=API, clock=Clock(t0), http=http
        )
        token = await provider.token()
        app_jwt = provider.app_jwt()
    assert token == "inst-token-secret-value"
    assert "inst-token-secret-value" not in caplog.text
    assert app_jwt not in caplog.text
    assert app_jwt.split(".")[2] not in caplog.text
    assert "inst-token-secret-value" not in repr(provider)
    assert key_path.read_text() not in caplog.text


def test_missing_key_file_raises_clear_error(tmp_path: Path) -> None:
    provider = InstallationTokenProvider(APP_ID, INSTALLATION_ID, tmp_path / "absent", api_url=API)
    with pytest.raises(FileNotFoundError):
        provider.app_jwt()
