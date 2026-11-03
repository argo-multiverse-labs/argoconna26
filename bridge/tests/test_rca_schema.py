"""Task 3.6: the strict RCA schema and model."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from bridge.rca import RCA, rca_json_schema

FIXTURES = Path(__file__).parent / "fixtures" / "holmes"


def _walk_objects(schema: dict):
    if schema.get("type") == "object":
        yield schema
    for value in schema.get("properties", {}).values():
        yield from _walk_objects(value)
    if isinstance(schema.get("items"), dict):
        yield from _walk_objects(schema["items"])


def test_schema_strict_all_required() -> None:
    for obj in _walk_objects(rca_json_schema()):
        assert set(obj["required"]) == set(obj["properties"]), obj


def test_schema_additional_properties_false_nested() -> None:
    objects = list(_walk_objects(rca_json_schema()))
    assert len(objects) == 2  # the RCA and proposed_patch
    for obj in objects:
        assert obj["additionalProperties"] is False


def test_schema_has_no_refs_or_unsupported_keywords() -> None:
    text = json.dumps(rca_json_schema())
    for keyword in ("$ref", "$defs", "minimum", "maximum", "maxItems", "pattern", "anyOf"):
        assert keyword not in text, keyword


def test_schema_fields_match_model() -> None:
    schema = rca_json_schema()
    assert set(schema["properties"]) == {
        name if f.alias is None else f.alias for name, f in RCA.model_fields.items()
    }
    patch = schema["properties"]["proposed_patch"]["properties"]
    assert set(patch) == {"file", "key", "from", "to"}


def test_schema_matches_the_spike_request() -> None:
    recorded = json.loads((FIXTURES / "chat_request_bridge_to_holmes.json").read_text())
    assert recorded["response_format"]["json_schema"]["schema"] == rca_json_schema()


VALID = {
    "root_cause": "x",
    "cause_commit_sha": "a" * 40,
    "evidence": ["Prometheus: y"],
    "delivery_context": "z",
    "confidence": 0.9,
    "proposed_patch": {"file": "apps/checkout/config/checkout-config.yaml", "key": "K", "from": "200", "to": "2000"},
}


def test_rca_aliases_from_and_to() -> None:
    rca = RCA.model_validate(VALID)
    assert rca.proposed_patch.from_value == "200"
    assert rca.proposed_patch.to_value == "2000"
    assert rca.model_dump(by_alias=True)["proposed_patch"]["from"] == "200"


@pytest.mark.parametrize(
    "change",
    [
        {"evidence": []},
        {"evidence": ["a", "b", "c", "d", "e", "f"]},
        {"confidence": 1.5},
        {"confidence": -0.1},
    ],
)
def test_rca_bounds(change: dict) -> None:
    with pytest.raises(ValidationError):
        RCA.model_validate({**VALID, **change})
