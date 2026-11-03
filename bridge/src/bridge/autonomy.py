"""The agent's autonomy level, read from `aiops/autonomy.yaml` in Git.

Anything missing, unreadable or invalid is treated as `suggest`: the least
autonomy is the safe default.
"""

from __future__ import annotations

import logging
from datetime import date
from typing import Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .forge import Forge, ForgeError, ForgeNotFound

log = logging.getLogger("bridge.autonomy")

Level = Literal["suggest", "propose", "act"]
AUTONOMY_PATH = "aiops/autonomy.yaml"


class Promotion(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    from_level: Level = Field(alias="from_level")
    dry_run_score: str  # "20/20" or "pending"
    approver_required: str  # the team, never a person
    approved_by: str | None = None  # a role plus a review link, or "admin-bypass"; never a login
    pr: int | None = None


class Autonomy(BaseModel):
    model_config = ConfigDict(extra="ignore")

    level: Level
    since: date
    promotion: Promotion | None = None
    touchpoints: dict[Level, int] = Field(default_factory=dict)


def failsafe() -> Autonomy:
    return Autonomy(level="suggest", since=date.today(), promotion=None, touchpoints={})


async def read_autonomy(forge: Forge, ref: str, path: str = AUTONOMY_PATH) -> tuple[Autonomy, str | None]:
    """Return the autonomy at `ref`, or the fail-safe `suggest` and the reason."""
    try:
        text = await forge.read_file(path, ref)
    except ForgeNotFound:
        return _failed(f"missing {path}")
    except ForgeError as exc:
        return _failed(f"forge error: {exc}")
    except Exception as exc:  # noqa: BLE001  the fail-safe must hold for anything
        return _failed(f"forge error: {type(exc).__name__}")

    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError:
        return _failed("parse error: not valid YAML")
    if not isinstance(data, dict):
        return _failed("parse error: not a mapping")
    try:
        return Autonomy.model_validate(data), None
    except ValidationError as exc:
        fields = ", ".join(sorted({".".join(str(p) for p in e["loc"]) for e in exc.errors()}))
        return _failed(f"invalid: {fields}")


def _failed(reason: str) -> tuple[Autonomy, str]:
    log.warning("autonomy fail-safe to suggest: %s", reason)
    return failsafe(), reason
