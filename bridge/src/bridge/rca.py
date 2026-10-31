"""The structured RCA HolmesGPT returns, and the strict JSON schema sent as `response_format`."""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class ProposedPatch(BaseModel):
    model_config = ConfigDict(populate_by_name=True, extra="ignore")

    file: str
    key: str
    from_value: str = Field(alias="from")
    to_value: str = Field(alias="to")


class RCA(BaseModel):
    model_config = ConfigDict(extra="ignore")

    root_cause: str
    cause_commit_sha: str
    evidence: list[str] = Field(min_length=1, max_length=5)
    delivery_context: str
    confidence: float = Field(ge=0, le=1)
    proposed_patch: ProposedPatch


def _strict_object(properties: dict[str, Any]) -> dict[str, Any]:
    return {
        "type": "object",
        "additionalProperties": False,
        "required": list(properties),
        "properties": properties,
    }


def rca_json_schema() -> dict[str, Any]:
    """Every property required and `additionalProperties: false` at every level.

    Kept to the keywords strict structured output accepts everywhere (no numeric
    bounds, no maxItems); `RCA` enforces the bounds after parsing.
    """
    string = {"type": "string"}
    return _strict_object(
        {
            "root_cause": string,
            "cause_commit_sha": string,
            "evidence": {"type": "array", "items": string},
            "delivery_context": string,
            "confidence": {"type": "number"},
            "proposed_patch": _strict_object(
                {"file": string, "key": string, "from": string, "to": string}
            ),
        }
    )
