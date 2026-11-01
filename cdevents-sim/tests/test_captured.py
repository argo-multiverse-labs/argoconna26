"""Payloads captured from a real Argo CD Notifications run (Task 3.3).

Each file is the raw body the webhook service posted to cdevents-sim, saved from the
store (GET /events). They prove the templates in platform/argocd/notifications-cdevents.yaml
produce events that pass the vendored v0.5.1 schema, which hand-written fixtures cannot.
"""

import json
from pathlib import Path

import pytest

from cdevents_sim.store import short_type
from cdevents_sim.validate import validate_event

CAPTURED = Path(__file__).parent / "fixtures" / "captured"
FILES = sorted(CAPTURED.glob("*.json"))
REQUIRED = {"service.deployed", "incident.detected", "incident.resolved"}


def test_captured_set_has_every_template_type():
    kinds = {short_type(json.loads(f.read_text())["context"]["type"]) for f in FILES}
    assert REQUIRED <= kinds, f"missing captured payloads for {sorted(REQUIRED - kinds)}"


@pytest.mark.parametrize("path", FILES, ids=lambda p: p.name)
def test_captured_payloads_validate(path):
    event = json.loads(path.read_text())
    validate_event(event)  # raises ValidationError on a schema miss
    assert event["context"]["source"].startswith("/argocd/")


def test_captured_incident_subject_ends_with_the_revision():
    for f in FILES:
        event = json.loads(f.read_text())
        if short_type(event["context"]["type"]).startswith("incident."):
            sid = event["subject"]["id"]
            assert "/incident-" in sid and len(sid.rsplit("-", 1)[1]) == 40, sid
