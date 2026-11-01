"""Webhook payloads."""

from __future__ import annotations

from datetime import datetime

from typing import Annotated

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field

# A full, lowercase commit SHA. Revisions go into GitHub API paths and the prompt, so
# anything else (a path, a branch name) is rejected with a 422.
Sha = Annotated[str, Field(pattern=r"^[0-9a-f]{40}$")]


class HistoryEntry(BaseModel):
    """One entry of the Application's `status.history` (extra Argo fields are ignored)."""

    model_config = ConfigDict(extra="ignore")

    id: int
    revision: Sha
    deployedAt: AwareDatetime


class ArgoDegradedHook(BaseModel):
    """The body the `bridge-app-degraded` Notifications template sends (Task 3.10)."""

    model_config = ConfigDict(extra="ignore")

    app: str = Field(min_length=1)
    namespace: str
    revision: Sha
    sync_revision: Sha
    health: str
    history: list[HistoryEntry] = Field(default_factory=list)
    repo_url: str
    target_revision: str
    # Set by the bridge on receipt, never taken from the body.
    received_at: datetime | None = Field(default=None, exclude=False)

    @property
    def key(self) -> str:
        return f"{self.app}@{self.revision}"
