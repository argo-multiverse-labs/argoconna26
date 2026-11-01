"""Guardrails: normalize the model's RCA, then refuse anything that doesn't check out.

The model's output varies in shape (a 7-character SHA, upper case, `200` versus
`"200"`, `./apps/...`). Normalizing first means a correct answer is never refused
for its formatting, and a wrong one is still refused. Every check runs, so every
refusal is reported, and any forge error fails closed.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Any, Literal

import yaml

from .config import Settings
from .forge import Forge, ForgeError
from .models import ArgoDegradedHook
from .rca import RCA

log = logging.getLogger("bridge.guardrails")

Reason = Literal["low_confidence", "cause_not_in_history", "file_not_allowed", "from_mismatch", "key_not_found"]

_FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
_SHORT_SHA = re.compile(r"^[0-9a-f]{7,39}$")


@dataclass(frozen=True)
class Refusal:
    reason: Reason
    detail: str


def normalize_value(value: Any) -> str:
    """`200`, `"200"`, `'200'` and ` 200 ` all become `200`."""
    if isinstance(value, bool):
        text = "true" if value else "false"
    else:
        text = str(value)
    text = text.strip()
    while len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        text = text[1:-1].strip()
    return text


def normalize_path(path: str) -> str:
    text = path.strip().replace("\\", "/")
    while text.startswith(("./", "/")):
        text = text[2:] if text.startswith("./") else text[1:]
    return text


def path_allowed(path: str, allowlist: list[str]) -> bool:
    parts = PurePosixPath(path).parts
    if not path or ".." in parts or "." in parts:
        return False
    return any(PurePosixPath(path).full_match(pattern) for pattern in allowlist)


def _short(sha: str) -> str:
    return sha[:7] if sha else "(empty)"


async def _resolve_cause(raw_sha: str, hook: ArgoDegradedHook, forge: Forge) -> str | None:
    sha = raw_sha.strip().lower()
    history = [h.revision.lower() for h in hook.history]
    if _FULL_SHA.match(sha):
        return sha
    if not _SHORT_SHA.match(sha):
        return None
    local = sorted({rev for rev in history if rev.startswith(sha)})
    if len(local) == 1:
        return local[0]
    resolved = await forge.resolve_sha(sha)
    return resolved.lower() if resolved else None


async def _check_cause(
    raw_sha: str, file: str, key: str, hook: ArgoDegradedHook, forge: Forge
) -> tuple[str, Refusal | None]:
    """Return the normalized SHA and a refusal, if any (Δ2: history, or an ancestor that changed the key)."""
    try:
        sha = await _resolve_cause(raw_sha, hook, forge)
        if sha is None:
            return raw_sha.strip().lower(), Refusal(
                "cause_not_in_history", f"commit {_short(raw_sha.strip())} is not a known commit"
            )
        if sha in {h.revision.lower() for h in hook.history}:
            return sha, None
        if await forge.is_ancestor(sha, hook.sync_revision) and await forge.commit_changed_key(sha, file, key):
            return sha, None
        return sha, Refusal(
            "cause_not_in_history",
            f"commit {_short(sha)} is not in the Argo history and did not change {key} in {file}",
        )
    except ForgeError as exc:
        log.warning("cause check failed closed: %s", exc)
        return raw_sha.strip().lower(), Refusal("cause_not_in_history", "could not verify the cause commit")


def _find_key(text: str, key: str) -> tuple[bool, Any]:
    """Look the key up in a ConfigMap's `data` only.

    Top-level fields (`kind`, `apiVersion`, `metadata`) and other kinds are never
    config values, so the agent can't patch them (matches the policy's rule 1).
    """
    for doc in yaml.safe_load_all(text):
        if not isinstance(doc, dict) or doc.get("kind") != "ConfigMap":
            continue
        data = doc.get("data")
        if isinstance(data, dict) and key in data:
            return True, data[key]
    return False, None


async def _check_from(file: str, key: str, from_value: str, forge: Forge, ref: str) -> Refusal | None:
    try:
        text = await forge.read_file(file, ref)
        found, current = _find_key(text, key)
    except ForgeError:
        return Refusal("key_not_found", f"could not read {file} on {ref}")
    except yaml.YAMLError:
        return Refusal("key_not_found", f"{file} is not valid YAML")
    if not found:
        return Refusal("key_not_found", f"{key} is not in {file}")
    if normalize_value(current) != from_value:
        return Refusal("from_mismatch", f"{file} has {key}={normalize_value(current)}, not {from_value}")
    return None


async def evaluate(
    rca: RCA, hook: ArgoDegradedHook, forge: Forge, settings: Settings
) -> tuple[RCA, list[Refusal]]:
    patch = rca.proposed_patch
    file = normalize_path(patch.file)
    key = patch.key.strip()
    from_value = normalize_value(patch.from_value)
    to_value = normalize_value(patch.to_value)
    refusals: list[Refusal] = []

    if rca.confidence < settings.confidence_threshold:
        refusals.append(
            Refusal("low_confidence", f"confidence {rca.confidence:.2f} < {settings.confidence_threshold:.2f}")
        )

    sha, cause_refusal = await _check_cause(rca.cause_commit_sha, file, key, hook, forge)
    if cause_refusal:
        refusals.append(cause_refusal)

    if not path_allowed(file, settings.config_allowlist):
        refusals.append(Refusal("file_not_allowed", f"{file or '(empty)'} is outside the config allow-list"))
    else:
        from_refusal = await _check_from(file, key, from_value, forge, settings.tracked_branch)
        if from_refusal:
            refusals.append(from_refusal)

    normalized = rca.model_copy(
        update={
            "cause_commit_sha": sha,
            "proposed_patch": patch.model_copy(
                update={"file": file, "key": key, "from_value": from_value, "to_value": to_value}
            ),
        }
    )
    return normalized, refusals
