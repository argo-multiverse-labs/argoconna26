"""Idempotency: one incident per app and synced revision."""

from __future__ import annotations

import threading
from collections.abc import Iterable


class IncidentRegistry:
    """The set of incident keys already handled or queued.

    After a restart it is rebuilt with `rehydrate` from open agent PRs and the
    bridge's own comments (Task 4.3), so a webhook replay does nothing.
    """

    def __init__(self) -> None:
        self._keys: set[str] = set()
        self._lock = threading.Lock()

    def seen(self, key: str) -> bool:
        with self._lock:
            return key in self._keys

    def mark(self, key: str) -> None:
        with self._lock:
            self._keys.add(key)

    def mark_if_new(self, key: str) -> bool:
        """Atomically mark `key`; True if it was new."""
        with self._lock:
            if key in self._keys:
                return False
            self._keys.add(key)
            return True

    def rehydrate(self, keys: Iterable[str]) -> None:
        with self._lock:
            self._keys.update(keys)

    def __len__(self) -> int:
        with self._lock:
            return len(self._keys)
