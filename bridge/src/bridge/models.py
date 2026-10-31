"""Webhook payloads."""

from __future__ import annotations

from datetime import datetime

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field


class HistoryEntry(BaseModel):
    """One entry of the Application's `status.history` (extra Argo fields are ignored)."""

    model_config = ConfigDict(extra="ignore")

    id: int
    revision: str = Field(min_length=1)
    deployedAt: AwareDatetime


class ArgoDegradedHook(BaseModel):
    """The body the `bridge-app-degraded` Notifications template sends (Task 3.10)."""

    model_config = ConfigDict(extra="ignore")

    app: str = Field(min_length=1)
    namespace: str
    revision: str = Field(min_length=1)
    sync_revision: str = Field(min_length=1)
    health: str
    history: list[HistoryEntry] = Field(default_factory=list)
    repo_url: str
    target_revision: str
    # Set by the bridge on receipt, never taken from the body.
    received_at: datetime | None = Field(default=None, exclude=False)

    @property
    def key(self) -> str:
        return f"{self.app}@{self.revision}"
