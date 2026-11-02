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


def test_optional_bridge_env_secret_for_test_hooks() -> None:
    """Task 4.6's failure paths set CONFIDENCE_THRESHOLD and the HolmesGPT timeout in the
    unmanaged Secret bridge-env (Argo self-heals the Deployment, so its env can't be edited)."""
    container = pod_spec()["containers"][0]
    refs = [e["secretRef"] for e in container.get("envFrom", []) if "secretRef" in e]
    assert {"name": "bridge-env", "optional": True} in refs
