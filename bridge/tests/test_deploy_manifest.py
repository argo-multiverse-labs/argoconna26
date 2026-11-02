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


def container_env_names() -> set[str]:
    return {e["name"] for e in pod_spec()["containers"][0].get("env", [])}


def test_envfrom_can_only_set_the_test_hooks() -> None:
    """The optional Secret bridge-env is loaded with envFrom, and a Deployment `env` entry
    beats envFrom. So every setting the bridge reads must be pinned in `env` under the
    first name Settings looks at, except the two test hooks, whose first name starts
    with TEST_ (slice-4 review: a stale bridge-env must not move the API host, the
    allow-list, DRY_FORGE or the repo)."""
    from bridge.config import TEST_HOOKS, Settings

    pinned = container_env_names()
    hooks = set()
    for name, f in Settings.model_fields.items():
        aliases = list(f.validation_alias.choices)
        if aliases[0].startswith("TEST_"):
            hooks.add(name)
            first_real = next(a for a in aliases if not a.startswith("TEST_"))
            assert first_real in pinned, f"{name}: {first_real} is not pinned in the Deployment env"
            continue
        assert aliases[0] in pinned, f"{name}: {aliases[0]} is not pinned in the Deployment env"
    assert hooks == set(TEST_HOOKS) == {"confidence_threshold", "holmes_timeout_s"}


def test_pinned_env_matches_the_settings_defaults() -> None:
    """The values pinned only to keep envFrom out must not change behaviour."""
    from bridge.config import Settings

    env = {e["name"]: e["value"] for e in pod_spec()["containers"][0]["env"] if "value" in e}
    s = Settings.model_validate({})
    defaults = Settings.model_fields
    for name in ("GITHUB_API_URL", "CONFIDENCE_THRESHOLD", "CONFIG_VERSION_ANNOTATION", "RECONCILE_APP"):
        assert name in env
    assert env["GITHUB_API_URL"] == defaults["github_api_url"].default
    assert float(env["CONFIDENCE_THRESHOLD"]) == defaults["confidence_threshold"].default
    assert env["DRY_FORGE"].lower() in ("false", "0")
    assert yaml.safe_load(env["CONFIG_ALLOWLIST"]) == s.config_allowlist
    assert env["CONFIG_VERSION_ANNOTATION"] == s.config_version_annotation
