import copy

import pytest

from conftest import change_created, change_merged, custom_event, incident, service_deployed
from cdevents_sim.validate import ValidationError, validate_event


def test_valid_service_deployed_accepted():
    validate_event(service_deployed())


@pytest.mark.parametrize(
    "event",
    [
        incident("detected", "i1"),
        incident("resolved", "i2"),
        change_merged(),
        change_created(),
    ],
)
def test_other_used_types_validate_against_v051_schema(event):
    validate_event(event)


def test_missing_context_id_rejected():
    e = service_deployed()
    del e["context"]["id"]
    with pytest.raises(ValidationError, match="context.id"):
        validate_event(e)


def test_schema_violation_rejected():
    e = service_deployed()
    del e["subject"]["content"]["artifactId"]
    with pytest.raises(ValidationError, match="schema violation"):
        validate_event(e)


def test_unknown_standard_type_rejected():
    e = service_deployed()
    e["context"]["type"] = "dev.cdevents.nothing.here.0.1.0"
    with pytest.raises(ValidationError):
        validate_event(e)


def test_custom_cdeventsx_type_accepted_without_schema():
    validate_event(custom_event("dev.cdeventsx.holmesgpt-rca.completed.0.1.0", "r1", custom={"anything": [1, 2]}))


def test_custom_type_still_needs_id_and_timestamp():
    e = custom_event("dev.cdeventsx.agent-action.0.1.0", "a1")
    bad = copy.deepcopy(e)
    del bad["context"]["timestamp"]
    with pytest.raises(ValidationError, match="timestamp"):
        validate_event(bad)


def test_non_object_rejected():
    with pytest.raises(ValidationError):
        validate_event([1])


def test_change_merged_040_is_rejected_because_v051_has_it_at_030():
    # The plan names change.merged 0.4.0; the vendored v0.5.1 schema has 0.3.0
    # (only change.created is at 0.4.0). Producers must send 0.3.0.
    e = change_merged()
    e["context"]["type"] = "dev.cdevents.change.merged.0.4.0"
    with pytest.raises(ValidationError, match="schema violation"):
        validate_event(e)


def test_operator_change_event_type_matches_vendored_schema():
    """O1: the operator scripts emit change.merged 0.3.0, the version v0.5.1 defines."""
    import json
    from pathlib import Path

    from test_store import operator_change_merged
    from cdevents_sim.validate import SCHEMA_DIR

    event = operator_change_merged()
    validate_event(event)
    schema = json.loads((SCHEMA_DIR / "changemerged.json").read_text())
    assert event["context"]["type"] in schema["properties"]["context"]["properties"]["type"]["enum"]
    assert event["context"]["type"] == "dev.cdevents.change.merged.0.3.0"
