"""Tests for policy/facts/facts.py.

Each test builds a throwaway git repo shaped like the demo (a checkout
ConfigMap, a Rollout with the config-version annotation, and a kustomization
holding the image tag), makes a fix branch, and runs facts.py as a subprocess,
the same way the policy-check Action and `make policy-check` call it.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

FACTS = Path(__file__).resolve().parent / "facts.py"

TRACKED = "trunk"
AGENT = "argoconna26-agent[bot]"

CONFIG = "apps/checkout/config/checkout-config.yaml"
ROLLOUT = "apps/checkout/deploy/rollout.yaml"
KUSTOMIZATION = "apps/checkout/kustomization.yaml"
RBAC = "apps/checkout/deploy/role.yaml"


def config_yaml(timeout: str) -> str:
    return f"""apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-config
data:
  # Upstream call timeout in milliseconds.
  UPSTREAM_TIMEOUT_MS: "{timeout}"
  PRICING_URL: "http://pricing.demo.svc:8080"
"""


def rollout_yaml(config_version: str, replicas: int = 4, image: str = "checkout") -> str:
    return f"""apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: checkout
  labels:
    example.dev/owner: payments-team
spec:
  replicas: {replicas}
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
        example.dev/owner: payments-team
      annotations:
        example.dev/config-version: "{config_version}"
    spec:
      containers:
        - name: checkout
          image: {image}
          imagePullPolicy: Never
          envFrom:
            - configMapRef:
                name: checkout-config
"""


def kustomization_yaml(tag: str) -> str:
    return f"""apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deploy/rollout.yaml
  - config/checkout-config.yaml
images:
  - name: checkout
    newTag: {tag}
"""


ROLE_YAML = """apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: checkout
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get"]
"""


class Repo:
    """A small git repo driven through the git CLI."""

    def __init__(self, path: Path) -> None:
        self.path = path
        path.mkdir(parents=True)
        self.git("init", "-q", "-b", TRACKED)
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "test")
        self.git("config", "commit.gpgsign", "false")

    def git(self, *args: str) -> str:
        out = subprocess.run(
            ["git", "-C", str(self.path), *args],
            check=True,
            capture_output=True,
            text=True,
        )
        return out.stdout.strip()

    def write(self, rel: str, text: str) -> None:
        target = self.path / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message: str, files: dict[str, str]) -> str:
        for rel, text in files.items():
            self.write(rel, text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def checkout(self, *args: str) -> None:
        self.git("checkout", "-q", *args)


@pytest.fixture
def demo(tmp_path: Path) -> dict:
    """Seeded history: healthy, PR-242 (2000 -> 200, no bump), image bump."""
    repo = Repo(tmp_path / "repo")
    healthy = repo.commit(
        "feat: checkout healthy",
        {
            CONFIG: config_yaml("2000"),
            ROLLOUT: rollout_yaml("7"),
            KUSTOMIZATION: kustomization_yaml("v1.4.1"),
        },
    )
    cause = repo.commit("tune upstream timeout for faster failover (#242)", {CONFIG: config_yaml("200")})
    bump = repo.commit("chore: bump checkout to v1.4.2", {KUSTOMIZATION: kustomization_yaml("v1.4.2")})
    return {"repo": repo, "healthy": healthy, "cause": cause, "bump": bump, "tmp": tmp_path}


def make_fix(demo: dict, files: dict[str, str], branch: str = "agent/checkout-fix") -> str:
    repo: Repo = demo["repo"]
    repo.checkout("-b", branch, demo["bump"])
    head = repo.commit("fix(checkout): restore UPSTREAM_TIMEOUT_MS to 2000 and roll config", files)
    repo.checkout(TRACKED)
    return head


def two_line_fix(timeout: str = "2000", config_version: str = "8") -> dict[str, str]:
    return {CONFIG: config_yaml(timeout), ROLLOUT: rollout_yaml(config_version)}


def run_facts(
    demo: dict,
    head: str,
    body: str | None = None,
    base: str | None = None,
    login: str = AGENT,
    author_type: str = "Bot",
) -> dict:
    proc = invoke(demo, head, body=body, base=base, login=login, author_type=author_type)
    assert proc.returncode == 0, proc.stderr
    return json.loads(proc.stdout)


def invoke(
    demo: dict,
    head: str,
    body: str | None = None,
    base: str | None = None,
    login: str = AGENT,
    author_type: str = "Bot",
) -> subprocess.CompletedProcess:
    if body is None:
        body = f"## Root cause\n\nCause: {demo['cause']} (tune upstream timeout)\n"
    body_file = demo["tmp"] / "body.md"
    body_file.write_text(body)
    return subprocess.run(
        [
            sys.executable,
            str(FACTS),
            "--repo",
            str(demo["repo"].path),
            "--base",
            base or demo["bump"],
            "--head",
            head,
            "--body-file",
            str(body_file),
            "--author-login",
            login,
            "--author-type",
            author_type,
            "--tracked-ref",
            TRACKED,
        ],
        capture_output=True,
        text=True,
    )


# --- The plan's tests (Task 5.1 Step 1) ---------------------------------------


def test_two_line_fix_facts(demo):
    facts = run_facts(demo, make_fix(demo, two_line_fix()))
    assert sorted(facts["changed_files"]) == sorted([CONFIG, ROLLOUT])
    assert facts["config_changes"] == [
        {"file": CONFIG, "key": "UPSTREAM_TIMEOUT_MS", "from": "200", "to": "2000"}
    ]
    assert facts["rollout_changes"] == {
        "file": ROLLOUT,
        "config_version": {"from": "7", "to": "8"},
        "other_changes": False,
    }
    assert facts["forbidden_changes"] == {"image": False, "rbac": False, "crd": False, "application": False}
    assert facts["to_value_seen_before"] is True
    assert facts["cited_sha"] == demo["cause"]
    assert facts["cited_sha_on_branch"] is True
    assert facts["cited_sha_changed_key"] is True
    assert facts["author"] == {"login": AGENT, "type": "Bot"}


def test_image_change_flagged(demo):
    files = two_line_fix()
    files[ROLLOUT] = rollout_yaml("8", image="checkout-evil")
    facts = run_facts(demo, make_fix(demo, files))
    assert facts["forbidden_changes"]["image"] is True
    assert facts["rollout_changes"]["other_changes"] is True


def test_kustomization_image_tag_change_flagged(demo):
    files = two_line_fix()
    files[KUSTOMIZATION] = kustomization_yaml("v1.4.3")
    facts = run_facts(demo, make_fix(demo, files))
    assert facts["forbidden_changes"]["image"] is True
    assert KUSTOMIZATION in facts["changed_files"]


def test_bold_or_short_cause_not_parsed(demo):
    head = make_fix(demo, two_line_fix())
    short = demo["cause"][:7]
    for body in (
        f"**Cause:** {short}\n",
        f"**Cause:** {demo['cause']}\n",
        f"Cause: {short}\n",
        f"Cause: {demo['cause'].upper()}\n",
        f"  Cause: {demo['cause']}\n",
        f"Cause: {demo['cause']}abc\n",
    ):
        facts = run_facts(demo, head, body=body)
        assert facts["cited_sha"] is None, body
        assert facts["cited_sha_on_branch"] is False
        assert facts["cited_sha_changed_key"] is False


def test_rbac_file_flagged(demo):
    files = two_line_fix()
    files[RBAC] = ROLE_YAML
    facts = run_facts(demo, make_fix(demo, files))
    assert facts["forbidden_changes"]["rbac"] is True
    assert facts["forbidden_changes"]["image"] is False


def test_other_rollout_change_flagged(demo):
    files = two_line_fix()
    files[ROLLOUT] = rollout_yaml("8", replicas=6)
    facts = run_facts(demo, make_fix(demo, files))
    assert facts["rollout_changes"]["other_changes"] is True
    assert facts["rollout_changes"]["config_version"] == {"from": "7", "to": "8"}
    assert facts["forbidden_changes"]["image"] is False


def test_to_value_seen_before_true_for_2000(demo):
    facts = run_facts(demo, make_fix(demo, two_line_fix("2000")))
    assert facts["to_value_seen_before"] is True


def test_to_value_seen_before_false_for_new_value(demo):
    facts = run_facts(demo, make_fix(demo, two_line_fix("2500")))
    assert facts["config_changes"][0]["to"] == "2500"
    assert facts["to_value_seen_before"] is False


def test_cited_sha_parsed_from_body(demo):
    head = make_fix(demo, two_line_fix())
    body = (
        "## Root cause\n\nThe timeout was cut to 200 ms.\n\n"
        f"Cause: {demo['cause']} (tune upstream timeout for faster failover)\n\n"
        "## Blast radius\n"
    )
    facts = run_facts(demo, head, body=body)
    assert facts["cited_sha"] == demo["cause"]


def test_cited_sha_not_on_branch(demo):
    repo: Repo = demo["repo"]
    repo.checkout("-b", "side", demo["healthy"])
    side = repo.commit("side: change timeout off branch", {CONFIG: config_yaml("300")})
    repo.checkout(TRACKED)
    head = make_fix(demo, two_line_fix())

    facts = run_facts(demo, head, body=f"Cause: {side} (side)\n")
    assert facts["cited_sha"] == side
    assert facts["cited_sha_on_branch"] is False

    missing = "0123456789abcdef0123456789abcdef01234567"
    facts = run_facts(demo, head, body=f"Cause: {missing} (nowhere)\n")
    assert facts["cited_sha"] == missing
    assert facts["cited_sha_on_branch"] is False
    assert facts["cited_sha_changed_key"] is False


def test_cited_sha_changed_key(demo):
    head = make_fix(demo, two_line_fix())
    assert run_facts(demo, head)["cited_sha_changed_key"] is True
    # The image-bump commit is on the branch but never touched the key.
    facts = run_facts(demo, head, body=f"Cause: {demo['bump']} (bump)\n")
    assert facts["cited_sha_on_branch"] is True
    assert facts["cited_sha_changed_key"] is False


def test_author_passthrough(demo):
    head = make_fix(demo, two_line_fix())
    facts = run_facts(demo, head, login="someone", author_type="User")
    assert facts["author"] == {"login": "someone", "type": "User"}


# --- Extra edge cases (fail closed) -------------------------------------------


def test_non_data_config_change_uses_path_key(demo):
    files = two_line_fix()
    files[CONFIG] = config_yaml("2000").replace("name: checkout-config", "name: other-config")
    facts = run_facts(demo, make_fix(demo, files))
    keys = sorted(c["key"] for c in facts["config_changes"])
    assert keys == ["/metadata", "UPSTREAM_TIMEOUT_MS"]


def test_crd_and_application_flagged(demo):
    files = two_line_fix()
    files["gitops/apps/extra.yaml"] = (
        "apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: extra\n"
    )
    files["apps/checkout/deploy/crd.yaml"] = (
        "apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata:\n  name: x.example.dev\n"
    )
    facts = run_facts(demo, make_fix(demo, files))
    assert facts["forbidden_changes"]["application"] is True
    assert facts["forbidden_changes"]["crd"] is True


def test_dockerfile_change_flagged_as_image(demo):
    files = two_line_fix()
    files["apps/checkout/Dockerfile"] = "FROM scratch\n"
    facts = run_facts(demo, make_fix(demo, files))
    assert facts["forbidden_changes"]["image"] is True


def test_diff_is_taken_from_merge_base(demo):
    """A base that moved on after the branch point doesn't show up as PR changes."""
    head = make_fix(demo, two_line_fix())
    repo: Repo = demo["repo"]
    later = repo.commit("docs: unrelated", {"README.md": "hello\n"})
    facts = run_facts(demo, head, base=later)
    assert sorted(facts["changed_files"]) == sorted([CONFIG, ROLLOUT])


def test_unknown_revision_fails(demo):
    proc = invoke(demo, "does-not-exist")
    assert proc.returncode != 0
    assert proc.stdout == ""


def test_option_like_revision_rejected(demo):
    proc = invoke(demo, "--output=/tmp/x")
    assert proc.returncode != 0
    assert proc.stdout == ""


def test_unparseable_yaml_fails(demo):
    files = two_line_fix()
    files[ROLLOUT] = "kind: Rollout\nspec: [unclosed\n"
    proc = invoke(demo, make_fix(demo, files))
    assert proc.returncode != 0
    assert proc.stdout == ""
