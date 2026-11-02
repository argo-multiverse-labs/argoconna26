"""Idempotency: one incident per app and synced revision."""

from __future__ import annotations

import threading
from collections.abc import Iterable

#: Fix-PR branches carry 7-character revisions, so rehydrated keys are `app@<7 hex>`.
SHORT_REVISION = 7


class IncidentRegistry:
    """The set of incident keys (`app@revision`) already handled or queued.

    After a restart it is rebuilt with `rehydrate` from the open agent PRs' branch names
    (Task 4.3), so a webhook replay does nothing. Those names carry only 7 characters of
    the revision, so a key also counts as seen when its short form (`app@abcdef1`) is in
    the set.

    It also holds the numbers of the fix PRs the act flow merged itself (Task 5.4): the
    pipeline emits `change.merged` for those, so the reconciler, which shares this registry,
    does not emit it a second time.
    """

    def __init__(self) -> None:
        self._keys: set[str] = set()
        self._merges: set[int] = set()
        self._lock = threading.Lock()

    def _known(self, key: str) -> bool:
        if key in self._keys:
            return True
        app, sep, revision = key.rpartition("@")
        return bool(sep) and len(revision) > SHORT_REVISION and f"{app}@{revision[:SHORT_REVISION]}" in self._keys

    def seen(self, key: str) -> bool:
        with self._lock:
            return self._known(key)

    def mark(self, key: str) -> None:
        with self._lock:
            self._keys.add(key)

    def mark_if_new(self, key: str) -> bool:
        """Atomically mark `key`; True if it was new."""
        with self._lock:
            if self._known(key):
                return False
            self._keys.add(key)
            return True

    def rehydrate(self, keys: Iterable[str]) -> None:
        """Add keys, full (`app@<40 hex>`) or short (`app@<7 hex>`)."""
        with self._lock:
            self._keys.update(keys)

    def announce_merge(self, number: int) -> None:
        """Called before the bridge's own merge request, so the reconciler can never see the
        merge first and announce it too."""
        with self._lock:
            self._merges.add(number)

    def forget_merge(self, number: int) -> None:
        """The merge request failed: a later merge (by a human or GitHub) is the reconciler's."""
        with self._lock:
            self._merges.discard(number)

    def merge_announced(self, number: int) -> bool:
        with self._lock:
            return number in self._merges

    def __len__(self) -> int:
        with self._lock:
            return len(self._keys)
