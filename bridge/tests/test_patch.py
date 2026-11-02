"""The deterministic fix builder (Task 4.2).

The model names the config change; the bridge writes it as a line-level edit of the
config file plus a +1 on the pod template's config-version annotation, and nothing
else. Comments, ordering and quoting survive because no YAML is ever re-dumped.
"""

from __future__ import annotations

import difflib
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

from bridge.patch import FixChange, PatchError, build_fix
from bridge.rca import RCA

CONFIG = "apps/checkout/config/checkout-config.yaml"
ROLLOUT = "apps/checkout/deploy/rollout.yaml"
ANNOTATION = "example.dev/config-version"
KEY = "UPSTREAM_TIMEOUT_MS"
CAUSE = "a" * 40

CONFIG_TEXT = """\
# checkout's runtime config; values are read once at pod start.
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-config
  labels:
    app: checkout
    example.dev/owner: payments-team
    example.dev/tier: "1"
    slo.example.dev/success-rate: "99"
data:
  # How long checkout waits on pricing, in milliseconds.
  UPSTREAM_TIMEOUT_MS: "200"  # tuned in PR-242
  PRICING_URL: http://pricing.demo.svc:8080
"""

ROLLOUT_TEXT = """\
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: checkout
  labels:
    app: checkout
spec:
  replicas: 4
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
      annotations:
        # Bump to roll the pods after a config change.
        example.dev/config-version: "7"
    spec:
      containers:
        - name: checkout
          image: checkout
"""


def rca(key: str = KEY, frm: str = "200", to: str = "2000", file: str = CONFIG) -> RCA:
    return RCA.model_validate(
        {
            "root_cause": "PR-242 cut the upstream timeout to 200 ms.",
            "cause_commit_sha": CAUSE,
            "evidence": ["pod logs: upstream timeout after 200 ms"],
            "delivery_context": "config changed at T-3d; nothing restarted until v1.4.2",
            "confidence": 0.9,
            "proposed_patch": {"file": file, "key": key, "from": frm, "to": to},
        }
    )


def build(config_text: str = CONFIG_TEXT, rollout_text: str = ROLLOUT_TEXT, **kw) -> FixChange:
    return build_fix(rca(**kw), config_text, rollout_text, ANNOTATION, rollout_path=ROLLOUT)


def changed_lines(before: str, after: str) -> list[tuple[str, str]]:
    """Pairs of (old, new) lines that differ; an added or removed line fails the caller."""
    a, b = before.splitlines(), after.splitlines()
    pairs: list[tuple[str, str]] = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=a, b=b, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        assert tag == "replace" and i2 - i1 == j2 - j1, f"lines added or removed: {tag} {a[i1:i2]} {b[j1:j2]}"
        pairs.extend(zip(a[i1:i2], b[j1:j2], strict=True))
    return pairs


def test_only_two_lines_change():
    fix = build()
    assert set(fix.files) == {CONFIG, ROLLOUT}
    config_pairs = changed_lines(CONFIG_TEXT, fix.files[CONFIG])
    rollout_pairs = changed_lines(ROLLOUT_TEXT, fix.files[ROLLOUT])
    assert len(config_pairs) + len(rollout_pairs) == 2
    assert config_pairs == [('  UPSTREAM_TIMEOUT_MS: "200"  # tuned in PR-242', '  UPSTREAM_TIMEOUT_MS: "2000"  # tuned in PR-242')]
    assert rollout_pairs == [('        example.dev/config-version: "7"', '        example.dev/config-version: "8"')]


def test_config_version_increment_by_one():
    fix = build()
    assert (fix.config_version_from, fix.config_version_to) == ("7", "8")
    rollout = yaml.safe_load(fix.files[ROLLOUT])
    assert rollout["spec"]["template"]["metadata"]["annotations"][ANNOTATION] == "8"
    multi_digit = build(rollout_text=ROLLOUT_TEXT.replace('config-version: "7"', 'config-version: "99"'))
    assert (multi_digit.config_version_from, multi_digit.config_version_to) == ("99", "100")


@pytest.mark.parametrize(
    ("before", "after"),
    [
        ('UPSTREAM_TIMEOUT_MS: "200"', 'UPSTREAM_TIMEOUT_MS: "2000"'),
        ("UPSTREAM_TIMEOUT_MS: '200'", "UPSTREAM_TIMEOUT_MS: '2000'"),
    ],
)
def test_quoting_preserved(before: str, after: str):
    config = CONFIG_TEXT.replace('UPSTREAM_TIMEOUT_MS: "200"', before)
    rollout = ROLLOUT_TEXT.replace('config-version: "7"', "config-version: '7'")
    fix = build(config_text=config, rollout_text=rollout)
    assert after in fix.files[CONFIG]
    assert "example.dev/config-version: '8'" in fix.files[ROLLOUT]
    assert yaml.safe_load(fix.files[CONFIG])["data"][KEY] == "2000"


def test_comments_preserved():
    fix = build()
    for text, out in ((CONFIG_TEXT, fix.files[CONFIG]), (ROLLOUT_TEXT, fix.files[ROLLOUT])):
        before = [line for line in text.splitlines() if "#" in line]
        after = [line for line in out.splitlines() if "#" in line]
        assert len(before) == len(after)
    assert "# checkout's runtime config; values are read once at pod start." in fix.files[CONFIG]
    assert "  # How long checkout waits on pricing, in milliseconds." in fix.files[CONFIG]
    assert "# tuned in PR-242" in fix.files[CONFIG]
    assert "        # Bump to roll the pods after a config change." in fix.files[ROLLOUT]
    # Ordering: the untouched key still follows the patched one, and the file still ends in a newline.
    out = fix.files[CONFIG]
    assert out.index(KEY) < out.index("PRICING_URL")
    assert out.endswith("\n")


def test_duplicate_key_raises():
    config = CONFIG_TEXT + '  UPSTREAM_TIMEOUT_MS: "300"\n'
    with pytest.raises(PatchError, match="more than once"):
        build(config_text=config)


@pytest.mark.parametrize("value", ['"seven"', '"7.5"', '""', '"-1"', "[7]"])
def test_non_integer_annotation_raises(value: str):
    rollout = ROLLOUT_TEXT.replace('config-version: "7"', f"config-version: {value}")
    with pytest.raises(PatchError, match="integer"):
        build(rollout_text=rollout)


def test_missing_annotation_raises():
    rollout = ROLLOUT_TEXT.replace('        example.dev/config-version: "7"\n', "")
    with pytest.raises(PatchError, match="missing"):
        build(rollout_text=rollout)


def test_annotation_outside_pod_template_raises():
    """The line edit must land on the pod template; a stray copy elsewhere is refused."""
    rollout = ROLLOUT_TEXT.replace(
        "  name: checkout\n  labels:", '  name: checkout\n  annotations:\n    example.dev/config-version: "3"\n  labels:', 1
    )
    with pytest.raises(PatchError, match="more than once"):
        build(rollout_text=rollout)


def test_missing_key_raises():
    with pytest.raises(PatchError, match="not found"):
        build(key="NOT_A_KEY")


def test_key_outside_configmap_data_raises():
    """A line that matches the key but sits outside `data` fails the re-parse check."""
    config = CONFIG_TEXT.replace('    app: checkout\n', '    app: checkout\n    UPSTREAM_TIMEOUT_MS: "200"\n').replace(
        '  UPSTREAM_TIMEOUT_MS: "200"  # tuned in PR-242\n', ""
    )
    with pytest.raises(PatchError):
        build(config_text=config)


def test_from_mismatch_raises():
    with pytest.raises(PatchError, match="not 300"):
        build(frm="300")


def test_no_op_raises():
    with pytest.raises(PatchError, match="already"):
        build(frm="200", to="200")


@pytest.mark.parametrize("to", ["2000\n  EVIL: x", "2000 # c", '20"00', "a: b"])
def test_unsafe_or_odd_values_stay_one_line_and_reparse(to: str):
    """A value from the model either lands as exactly that string on one line, or is refused."""
    try:
        fix = build(to=to)
    except PatchError:
        return
    assert yaml.safe_load(fix.files[CONFIG])["data"][KEY] == to
    assert len(changed_lines(CONFIG_TEXT, fix.files[CONFIG])) == 1


def test_newline_in_value_raises():
    with pytest.raises(PatchError, match="one line"):
        build(to="2000\nEVIL: x")


def test_paths_normalized_and_summary():
    fix = build(file="./" + CONFIG)
    assert set(fix.files) == {CONFIG, ROLLOUT}
    assert fix.diff_summary == [
        f"{CONFIG}: {KEY} 200 → 2000",
        f"{ROLLOUT}: {ANNOTATION} 7 → 8",
    ]


def test_crlf_line_endings_preserved():
    fix = build(config_text=CONFIG_TEXT.replace("\n", "\r\n"), rollout_text=ROLLOUT_TEXT.replace("\n", "\r\n"))
    assert '  UPSTREAM_TIMEOUT_MS: "2000"  # tuned in PR-242\r\n' in fix.files[CONFIG]
    assert fix.files[ROLLOUT].count("\r\n") == ROLLOUT_TEXT.count("\n")


def test_real_repo_files_patch_cleanly():
    """The committed checkout files, armed: the builder's output is the scripted fix's shape."""
    root = Path(__file__).resolve().parents[2]
    config = (root / CONFIG).read_text().replace('UPSTREAM_TIMEOUT_MS: "2000"', 'UPSTREAM_TIMEOUT_MS: "200"')
    rollout = (root / ROLLOUT).read_text()
    fix = build(config_text=config, rollout_text=rollout)
    assert len(changed_lines(config, fix.files[CONFIG])) + len(changed_lines(rollout, fix.files[ROLLOUT])) == 2
    assert int(fix.config_version_to) == int(fix.config_version_from) + 1


@pytest.mark.skip(reason="enabled in Task 5.2 Step 3")
def test_output_passes_policy_fixture(tmp_path: Path):
    """The produced diff and the rendered fix-PR body satisfy autofix rules 1, 2, 4 and 5.

    Needs Task 4.3's body renderer and Tasks 5.1-5.2's `policy/facts/facts.py` and
    `policy/autofix.rego` on the branch. Task 5.2 Step 3 removes the skip marker.
    """
    from bridge.pipeline import render_fix_pr_body  # Task 4.3

    root = Path(__file__).resolve().parents[2]
    conftest = shutil.which("conftest")
    assert conftest, "conftest is required"

    repo = tmp_path / "repo"

    def git(*args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(repo), *args], check=True, capture_output=True, text=True
        ).stdout.strip()

    def write(rel: str, text: str) -> None:
        (repo / rel).parent.mkdir(parents=True, exist_ok=True)
        (repo / rel).write_text(text)

    repo.mkdir()
    git("init", "-q", "-b", "build/demo")
    git("config", "user.email", "test@example.invalid")
    git("config", "user.name", "test")
    write(CONFIG, CONFIG_TEXT.replace('"200"', '"2000"'))
    write(ROLLOUT, ROLLOUT_TEXT)
    git("add", "-A")
    git("commit", "-qm", "seed")
    write(CONFIG, CONFIG_TEXT)
    git("commit", "-qam", "PR-242 replay: tune upstream timeout")
    cause = git("rev-parse", "HEAD")
    base = cause

    fix = build_fix(
        rca().model_copy(update={"cause_commit_sha": cause}), CONFIG_TEXT, ROLLOUT_TEXT, ANNOTATION, rollout_path=ROLLOUT
    )
    git("checkout", "-qb", "agent/checkout-fix")
    for path, text in fix.files.items():
        write(path, text)
    git("commit", "-qam", "fix(checkout): restore UPSTREAM_TIMEOUT_MS to 2000 and roll config")
    head = git("rev-parse", "HEAD")

    body = tmp_path / "body.md"
    body.write_text(render_fix_pr_body(rca().model_copy(update={"cause_commit_sha": cause}), fix, level="propose"))
    facts = subprocess.run(
        [
            "python3", str(root / "policy/facts/facts.py"),
            "--repo", str(repo), "--base", base, "--head", head, "--body-file", str(body),
            "--author-login", "argoconna26-agent[bot]", "--author-type", "Bot", "--tracked-ref", "build/demo",
        ],
        check=True, capture_output=True, text=True,
    ).stdout
    (tmp_path / "facts.json").write_text(facts)
    result = subprocess.run(
        [conftest, "test", "-p", str(root / "policy"), "-d", str(root / "policy/data"),
         "--namespace", "autofix", "-o", "json", str(tmp_path / "facts.json")],
        check=False, capture_output=True, text=True,
    )
    for rule in ("rule 1:", "rule 2:", "rule 4:", "rule 5:"):
        assert rule not in result.stdout, result.stdout
