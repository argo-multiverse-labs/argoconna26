"""Spec 10: the bridge's tests run without network access.

pytest-socket blocks every inet socket for the whole suite (`--disable-socket`,
Unix sockets stay allowed because asyncio's self-pipe needs one), and an autouse
respx router refuses any httpx request no route matches.
"""

from __future__ import annotations

import socket

import httpx
import pytest
from pytest_socket import SocketBlockedError
from respx.models import AllMockedAssertionError


@pytest.mark.filterwarnings("ignore:A test tried to use socket.socket")
def test_inet_socket_is_blocked() -> None:
    with pytest.raises(SocketBlockedError):
        socket.socket(socket.AF_INET, socket.SOCK_STREAM)


async def test_unmocked_httpx_request_fails() -> None:
    async with httpx.AsyncClient() as http:
        with pytest.raises(AllMockedAssertionError):
            await http.get("http://example.invalid/")
