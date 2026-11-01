"""The bridge Deployment must let UID 10001 read its mounted GitHub App key."""

from __future__ import annotations

from pathlib import Path

import yaml

DEPLOYMENT = Path(__file__).resolve().parents[1] / "deploy" / "deployment.yaml"


def pod_spec() -> dict:
    return yaml.safe_load(DEPLOYMENT.read_text())["spec"]["template"]["spec"]


def test_fsgroup_lets_the_bridge_user_read_secret_volumes() -> None:
    spec = pod_spec()
    ctx = spec["securityContext"]
    assert ctx["fsGroup"] == ctx["runAsUser"]
    for vol in spec["volumes"]:
        if "secret" in vol:
            mode = vol["secret"].get("defaultMode", 0o644)
            assert mode & 0o040, f"{vol['name']}: group cannot read (mode {mode:o})"
            assert not mode & 0o007, f"{vol['name']}: others can read (mode {mode:o})"
