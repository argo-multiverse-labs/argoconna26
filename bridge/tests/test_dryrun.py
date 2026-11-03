"""Task 6.2: the dry-run harness. Fake forge, stub HolmesGPT, stub cluster and timeline; the
policy test uses a local fixture repo with the real facts.py and conftest (skipped without conftest).
No network, no cluster, no push."""

from __future__ import annotations

import json
import shutil
import subprocess
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from bridge.config import Settings
from bridge.dryrun import (
    BatchConfig,
    DriftError,
    ExpectedError,
    GitPolicy,
    PolicyToolError,
    PreconditionError,
    ReadOnlyForge,
    ReadOnlyViolation,
    expected_from_git,
    run_batch,
    summarize,
    write_outputs,
)
from bridge.forge import PullRequest
from bridge.forge.fake import FakeForge
from bridge.holmes import HolmesBadOutput, HolmesResult, HolmesTimeout
from bridge.incidents import IncidentRegistry
from bridge.patch import build_fix
from bridge.pipeline import render_fix_pr_body
from bridge.rca import RCA
from bridge.score import Expected

from bridge import dryrun

REPO_ROOT = Path(__file__).resolve().parents[2]
POLICY_DIR = REPO_ROOT / "policy"
BRANCH = "build/demo"
CONFIG = "apps/checkout/config/checkout-config.yaml"
ROLLOUT = "apps/checkout/deploy/rollout.yaml"
KEY = "UPSTREAM_TIMEOUT_MS"
CAUSE = "c" * 40
BUMP = "e" * 40
OLD = "1" * 40
HEAD = "f" * 40
REF = "CHG-K7Q2ZB"
ABORT = datetime(2026, 11, 5, 17, 40, 0, tzinfo=UTC)
TIMELINE_CALLS = ["GET /timeline", "prometheus range query"]

CONFIGMAP = """\
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-config
data:
  UPSTREAM_TIMEOUT_MS: "{value}"
  PRICING_URL: http://pricing.demo.svc:8080
"""
ROLLOUT_TEXT = """\
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: checkout
spec:
  template:
    metadata:
      annotations:
        example.dev/config-version: "7"
    spec:
      containers:
        - name: checkout
          image: checkout
"""
AUTONOMY = """\
apiVersion: aiops.example.dev/v1
kind: Autonomy
level: {level}
since: "2026-11-02"
promotion: null
touchpoints: {{suggest: 4, propose: 1, act: 1}}
"""
EXPECTED = Expected(cause_sha=CAUSE, file=CONFIG, key=KEY, from_value="200", to_value="2000", change_ref=REF)


def rca(**overrides: object) -> RCA:
    data: dict = {
        "root_cause": "PR-242 cut UPSTREAM_TIMEOUT_MS to 200 without bumping config-version.",
        "cause_commit_sha": CAUSE,
        "evidence": ["Prometheus: pods started after the change report 200"],
        "delivery_context": f"{REF} merged 4 minutes before the abort, config only.",
        "confidence": 0.9,
        "proposed_patch": {"file": CONFIG, "key": KEY, "from": "200", "to": "2000"},
    }
    data.update(overrides)
    return RCA.model_validate(data)


# -- stubs ---------------------------------------------------------------------------


def make_forge(level: str = "suggest", armed: str = "200") -> FakeForge:
    forge = FakeForge()
    forge.files[("aiops/autonomy.yaml", BRANCH)] = AUTONOMY.format(level=level)
    forge.files[(CONFIG, BRANCH)] = CONFIGMAP.format(value=armed)
    forge.files[(CONFIG, HEAD)] = CONFIGMAP.format(value=armed)
    forge.files[(ROLLOUT, HEAD)] = ROLLOUT_TEXT
    forge.heads[BRANCH] = HEAD
    forge.commits.extend([CAUSE, BUMP, OLD, HEAD])
    return forge


class StubHolmes:
    def __init__(self, *answers: RCA | BaseException, tool_calls: list[str] | None = None) -> None:
        self.answers = list(answers) or [rca()]
        self.tool_calls = TIMELINE_CALLS if tool_calls is None else tool_calls
        self.prompts: list[str] = []

    async def investigate(self, prompt: str) -> HolmesResult:
        self.prompts.append(prompt)
        answer = self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]
        if isinstance(answer, BaseException):
            raise answer
        return HolmesResult(rca=answer, tool_calls=list(self.tool_calls), raw_analysis="{}", latency_s=42.0)


def application(health: str = "Degraded", revision: str = BUMP, synced: str = BUMP) -> dict:
    return {
        "spec": {"destination": {"namespace": "demo"},
                 "source": {"repoURL": "https://github.com/example-org/example-repo", "targetRevision": BRANCH}},
        "status": {
            "health": {"status": health},
            "sync": {"revision": revision},
            "operationState": {"syncResult": {"revision": synced}},
            "history": [
                {"id": 7, "revision": OLD, "deployedAt": "2026-11-05T17:30:00Z"},
                {"id": 8, "revision": CAUSE, "deployedAt": "2026-11-05T17:35:00Z"},
                {"id": 9, "revision": BUMP, "deployedAt": "2026-11-05T17:38:00Z"},
            ],
        },
    }


class StubCluster:
    def __init__(self, *states: dict) -> None:
        self.states = list(states) or [application()]
        self.reads = 0

    async def application(self, app: str) -> dict:
        self.reads += 1
        return self.states.pop(0) if len(self.states) > 1 else self.states[0]


class StubTimeline:
    def __init__(self, ok: bool = True) -> None:
        self.ok = ok
        self.asked: list[tuple[str, str, str]] = []

    async def has_change(self, app: str, sha: str, change_ref: str) -> bool:
        self.asked.append((app, sha, change_ref))
        return self.ok


class StubPolicy:
    def __init__(self, result: bool | BaseException = True) -> None:
        self.result = result
        self.calls: list[tuple[str, dict]] = []

    def check(self, base_sha: str, files: dict[str, str], body: str, commit_message: str) -> bool:
        self.calls.append((base_sha, files))
        if isinstance(self.result, BaseException):
            raise self.result
        return self.result


class StubChat:
    def __init__(self, verdict: str = "correct") -> None:
        self.verdict = verdict
        self.calls = 0

    async def chat(self, body: dict) -> dict:
        self.calls += 1
        return {"choices": [{"message": {"content": json.dumps({"verdict": self.verdict, "reason": "ok"})}}]}


class RecordingEmitter:
    def __init__(self) -> None:
        self.events: list[dict] = []

    async def emit(self, event: dict) -> None:
        self.events.append(event)


def cfg(n: int = 3, batch_id: int = 1, threshold: float = 0.7) -> BatchConfig:
    return BatchConfig(app="checkout", batch_id=batch_id, n=n, bump=BUMP, abort_at=ABORT, threshold=threshold,
                       armed_value="200", config_file=CONFIG, config_key=KEY)


class Clock:
    def __init__(self, start: datetime) -> None:
        self.now = start

    def __call__(self) -> datetime:
        self.now += timedelta(seconds=30)
        return self.now


@pytest.fixture
def settings() -> Settings:
    return Settings(github_repo="example-org/example-repo", tracked_branch=BRANCH, argo_ui_url="http://127.0.0.1:30080")


async def batch(settings: Settings, *, forge=None, holmes=None, cluster=None, timeline=None, policy=None,
                judge=None, config=None, **kw):
    return await run_batch(
        config or cfg(), EXPECTED, forge=forge or make_forge(), holmes=holmes or StubHolmes(),
        cluster=cluster or StubCluster(), timeline=timeline or StubTimeline(), policy=policy or StubPolicy(),
        judge_client=judge or StubChat(), settings=settings, clock=kw.pop("clock", Clock(ABORT)), **kw,
    )


# -- the read-only forge and the emitter ------------------------------------------


async def test_readonly_forge_blocks_writes():
    inner = make_forge()
    ro = ReadOnlyForge(inner)
    assert "level: suggest" in await ro.read_file("aiops/autonomy.yaml", BRANCH)
    assert await ro.branch_head(BRANCH) == HEAD
    pr = PullRequest(1, "u", "n", "h", "agent/checkout-ccccccc-eeeeeee")
    writes = [
        ro.comment_on_commit(CAUSE, "x"),
        ro.comment_on_pr(1, "x"),
        ro.open_pr(BRANCH, "agent/checkout-ccccccc-eeeeeee", "t", "b", {CONFIG: "x"}, "m"),
        ro.enable_auto_merge(pr, "merge"),
        ro.merge_pr(pr, "merge"),
    ]
    for write in writes:
        with pytest.raises(ReadOnlyViolation):
            await write
    assert ro.attempts == ["comment_on_commit", "comment_on_pr", "open_pr", "enable_auto_merge", "merge_pr"]
    assert inner.commit_comments == [] and inner.pr_comments == [] and inner.opened == []
    assert inner.merged == [] and inner.auto_merges == []
    # Not a ForgeError: the pipeline's "record the failed post and go on" path can't swallow it.
    from bridge.forge import ForgeError
    assert not issubclass(ReadOnlyViolation, ForgeError)


async def test_dryrun_emits_no_events(settings):
    forge, emitter = make_forge(), RecordingEmitter()
    results = await batch(settings, forge=forge, emitter=emitter, config=cfg(n=1))
    assert len(results) == 1 and results[0]["score"]["matched"]
    assert emitter.events == []
    # and nothing was written to the forge either
    assert forge.commit_comments == [] and forge.pr_comments == [] and forge.opened == []


# -- preconditions and drift ----------------------------------------------------------


@pytest.mark.parametrize("level", ["propose", "act", "nonsense"])
async def test_refuses_unless_suggest(settings, level):
    holmes = StubHolmes()
    with pytest.raises(PreconditionError):
        await batch(settings, forge=make_forge(level=level), holmes=holmes)
    assert holmes.prompts == []


async def test_drift_aborts_without_summary(settings, tmp_path):
    holmes = StubHolmes()
    # Run 1 sees the frozen incident; before run 2 the Application has gone Healthy (someone fixed it).
    cluster = StubCluster(application(), application(), application(health="Healthy"))
    seen: list[dict] = []
    with pytest.raises(DriftError):
        await batch(settings, holmes=holmes, cluster=cluster, on_result=seen.append)
    assert len(seen) == 1 and len(holmes.prompts) == 1

    # A new revision synced (the fix landed) is drift too, and so is a disarmed config.
    with pytest.raises(DriftError):
        await batch(settings, cluster=StubCluster(application(), application(revision=HEAD)))
    with pytest.raises(DriftError):
        await batch(settings, forge=make_forge(armed="2000"))
    # The batch must start on the bump's own sync, not an older one.
    with pytest.raises(DriftError):
        await batch(settings, cluster=StubCluster(application(synced=OLD)))

    # An aborted batch file never becomes a summary.
    run_dir = tmp_path / "run"
    run_dir.mkdir()
    (run_dir / "batch-1.json").write_text(json.dumps({"batch": 1, "n": 3, "aborted": "drift", "results": seen}))
    summary = tmp_path / "summary.json"
    with pytest.raises(dryrun.SummaryError):
        write_outputs(run_dir, 1, results_out=tmp_path / "results.json", summary_out=summary,
                      model_temperature=1.0, model_id="m")
    assert not summary.exists()
    rc = dryrun.main(["--summarize", str(run_dir), "--batches", "1", "--results-out", str(tmp_path / "r.json"),
                      "--summary-out", str(summary), "--model-temperature", "1", "--model-id", "m"])
    assert rc != 0 and not summary.exists()


async def test_timeline_must_hold_the_change_ref(settings):
    timeline = StubTimeline(ok=False)
    with pytest.raises(ExpectedError):
        await batch(settings, timeline=timeline)
    assert timeline.asked == [("checkout", CAUSE, REF)]


# -- expected from git ---------------------------------------------------------------


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def commit(repo: Path, files: dict[str, str], message: str) -> str:
    for path, text in files.items():
        (repo / path).parent.mkdir(parents=True, exist_ok=True)
        (repo / path).write_text(text)
    git(repo, "add", "--", *files)
    git(repo, "commit", "-q", "-m", message)
    return git(repo, "rev-parse", "HEAD")


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    r = tmp_path / "repo"
    r.mkdir()
    git(r, "init", "-q", "-b", BRANCH)
    for k, v in (("user.email", "test@example.invalid"), ("user.name", "test"), ("commit.gpgsign", "false")):
        git(r, "config", k, v)
    commit(r, {CONFIG: CONFIGMAP.format(value="2000"), ROLLOUT: ROLLOUT_TEXT}, "base")
    return r


def test_expected_from_latest_rearm_trailer(repo):
    commit(repo, {CONFIG: CONFIGMAP.format(value="200")}, "PR-242: tune upstream timeout\n\nDemo-Seed: pr-242")
    commit(repo, {CONFIG: CONFIGMAP.format(value="2000")}, "disarm")
    cause = commit(repo, {CONFIG: CONFIGMAP.format(value="200")}, "PR-242 replay\n\nDemo-Rearm: 1")
    commit(repo, {"apps/checkout/kustomization.yaml": "images: []\n"}, "bump checkout to v1.4.2")
    # A newer trailer commit on another branch is not on the tracked ref.
    git(repo, "checkout", "-q", "-b", "side")
    commit(repo, {CONFIG: CONFIGMAP.format(value="2000")}, "x\n\nDemo-Rearm: 9")
    git(repo, "checkout", "-q", BRANCH)

    exp = expected_from_git(repo, BRANCH, REF)
    assert exp == Expected(cause_sha=cause, file=CONFIG, key=KEY, from_value="200", to_value="2000", change_ref=REF)


def test_expected_refuses_without_trailer_or_with_a_wide_commit(repo):
    with pytest.raises(ExpectedError):
        expected_from_git(repo, BRANCH, REF)
    commit(repo, {CONFIG: CONFIGMAP.format(value="200"), ROLLOUT: ROLLOUT_TEXT + "#\n"}, "two files\n\nDemo-Rearm: 1")
    with pytest.raises(ExpectedError):
        expected_from_git(repo, BRANCH, REF)
    with pytest.raises(ExpectedError):
        expected_from_git(repo, BRANCH, "not-a-ref")


# -- per-iteration state, denominator, threshold ------------------------------------


async def test_fresh_registry_per_iteration(settings):
    made: list[IncidentRegistry] = []

    def factory() -> IncidentRegistry:
        made.append(IncidentRegistry())
        return made[-1]

    results = await batch(settings, registry_factory=factory)
    assert len(results) == 3
    assert len({id(r) for r in made}) == 3
    assert all(len(r) == 1 for r in made)  # each saw exactly its own run
    assert all(r["score"]["root_cause_matched"] for r in results)


async def test_failures_count_in_n_and_not_matched(settings, tmp_path):
    holmes = StubHolmes(HolmesTimeout("115 s"), HolmesBadOutput("not JSON"), rca())
    judge = StubChat("correct")
    results = await batch(settings, holmes=holmes, judge=judge)
    assert [r["holmes_failed"] for r in results] == [True, False, False]
    assert [r["bad_output"] for r in results] == [False, True, False]
    assert [r["score"]["root_cause_matched"] for r in results] == [False, False, True]
    assert [r["judge"]["verdict"] for r in results] == ["wrong", "wrong", "correct"]
    assert judge.calls == 1  # no judge call without an RCA
    s = summarize([{"batch": 1, "n": 3, "results": results}], model_temperature=1.0, model_id="m")
    assert (s["n"], s["root_cause_matched"], s["holmes_failed"], s["bad_output"]) == (3, 1, 1, 1)


async def test_scored_at_threshold_before_run(settings, monkeypatch):
    # The live threshold (0.7) is what the batch was started with; a later change in the
    # environment or settings object doesn't move it, and a low-confidence answer is a refusal.
    monkeypatch.setenv("CONFIDENCE_THRESHOLD", "0.1")
    holmes = StubHolmes(rca(confidence=0.65), rca(confidence=0.95))
    results = await batch(settings, holmes=holmes, config=cfg(n=2, threshold=0.7))
    assert [r["threshold_used"] for r in results] == [0.7, 0.7]
    assert results[0]["refusals"][0]["reason"] == "low_confidence"
    assert not results[0]["score"]["root_cause_matched"]
    assert results[1]["score"]["root_cause_matched"]
    assert settings.confidence_threshold == 0.7  # the caller's settings object is untouched
    s = summarize([{"batch": 1, "n": 2, "results": results}], model_temperature=1.0, model_id="m")
    assert s["threshold_used"] == 0.7 and s["refusals"] == 1
    other = [dict(results[1], threshold_used=0.5)]
    with pytest.raises(dryrun.SummaryError):
        summarize([{"batch": 1, "n": 2, "results": results}, {"batch": 2, "n": 1, "results": other}],
                  model_temperature=1.0, model_id="m")


async def test_seconds_since_abort_recorded(settings):
    results = await batch(settings, clock=Clock(ABORT + timedelta(minutes=2)))
    gaps = [r["seconds_since_abort"] for r in results]
    assert gaps[0] >= 120 and gaps == sorted(gaps) and len(set(gaps)) == 3
    assert all(r["started_at"].endswith("Z") for r in results)


# -- policy_ok ------------------------------------------------------------------------


async def test_policy_tool_error_aborts_not_false(settings):
    seen: list[dict] = []
    with pytest.raises(PolicyToolError):
        await batch(settings, policy=StubPolicy(PolicyToolError("conftest output does not parse")),
                    on_result=seen.append)
    assert seen == []  # never recorded as policy_ok=false


def test_policy_tool_errors_from_the_tools(tmp_path, repo):
    base = git(repo, "rev-parse", "HEAD")
    stubs = tmp_path / "bin"
    stubs.mkdir()

    def stub(name: str, script: str) -> str:
        p = stubs / name
        p.write_text("#!/usr/bin/env bash\n" + script + "\n")
        p.chmod(0o755)
        return str(p)

    facts_ok = stub("facts-ok", 'echo "{}"')
    facts_bad = stub("facts-bad", "exit 2")
    good = stub("conftest-good", 'case "$1" in --version) echo "Conftest: 0.71.1";; '
                '*) echo \'[{"filename":"f","namespace":"autofix","successes":6,"failures":[]}]\';; esac')
    garbage = stub("conftest-garbage", 'case "$1" in --version) echo "Conftest: 0.71.1";; *) echo "oops";; esac')
    old = stub("conftest-old", 'echo "Conftest: 0.60.0"')
    crash = stub("conftest-crash", 'case "$1" in --version) echo "Conftest: 0.71.1";; *) exit 2;; esac')
    fix = {CONFIG: CONFIGMAP.format(value="3000")}  # differs from the base, so the commit is not empty

    def policy(conftest: str, facts: str) -> GitPolicy:
        return GitPolicy(repo, POLICY_DIR, BRANCH, "argoconna26-agent[bot]", "v0.71.1",
                         facts=Path(facts), python="bash", conftest=conftest)

    assert policy(good, facts_ok).check(base, fix, "body", "msg") is True
    for conftest, facts in ((garbage, facts_ok), (old, facts_ok), (crash, facts_ok), (good, facts_bad),
                            (str(stubs / "missing"), facts_ok)):
        with pytest.raises(PolicyToolError):
            policy(conftest, facts).check(base, fix, "body", "msg")
    # the scratch clone is left at the base, clean
    assert git(repo, "rev-parse", "HEAD") == base and git(repo, "status", "--porcelain") == ""


@pytest.mark.skipif(shutil.which("conftest") is None, reason="conftest not installed")
def test_policy_ok_from_temp_commit(tmp_path, repo):
    """The real facts.py and conftest on a temporary commit in a clone; nothing is pushed."""
    cause = commit(repo, {CONFIG: CONFIGMAP.format(value="200")}, "PR-242 replay\n\nDemo-Rearm: 1")
    origin = tmp_path / "origin.git"
    git(tmp_path, "clone", "-q", "--bare", str(repo), str(origin))
    scratch = tmp_path / "scratch"
    git(tmp_path, "clone", "-q", str(origin), str(scratch))
    tracked = f"origin/{BRANCH}"
    base = git(scratch, "rev-parse", tracked)
    before = git(origin, "for-each-ref")
    version = subprocess.run(["conftest", "--version"], capture_output=True, text=True, check=True).stdout.split()[1]

    answer = rca(cause_commit_sha=cause)
    fix = build_fix(answer, CONFIGMAP.format(value="200"), ROLLOUT_TEXT, "example.dev/config-version",
                    rollout_path=ROLLOUT)
    body = render_fix_pr_body(answer, fix, level="act")
    policy = GitPolicy(scratch, POLICY_DIR, tracked, "argoconna26-agent[bot]", version)
    assert policy.check(base, fix.files, body, f"fix(checkout): restore\n\nCause: {cause}") is True

    # The same fix plus an image change is denied (rule 1 and rule 4): false, not an error.
    worse = dict(fix.files)
    worse[ROLLOUT] = worse[ROLLOUT].replace("image: checkout", "image: checkout:v9")
    assert policy.check(base, worse, body, "fix") is False

    assert git(origin, "for-each-ref") == before  # nothing pushed
    assert git(scratch, "rev-parse", "HEAD") == base and git(scratch, "status", "--porcelain") == ""


async def test_policy_runs_only_with_a_fix(settings):
    policy = StubPolicy(True)
    results = await batch(settings, policy=policy, holmes=StubHolmes(rca(cause_commit_sha="d" * 40)),
                          config=cfg(n=1))
    assert policy.calls == []  # refused (cause unknown): no fix to check
    assert results[0]["score"]["policy_ok"] is False and results[0]["refusals"]
    results = await batch(settings, policy=policy, config=cfg(n=1))
    assert len(policy.calls) == 1 and policy.calls[0][0] == HEAD
    assert set(policy.calls[0][1]) == {CONFIG, ROLLOUT}
    assert results[0]["score"]["matched"]


# -- the summary ------------------------------------------------------------------------


def _run(batch_id: int, cause: str, matched: bool, latency: float = 40.0, cited: bool = True) -> dict:
    return {
        "batch": batch_id, "cause_sha": cause, "threshold_used": 0.7, "holmes_failed": False,
        "bad_output": False, "pii_kinds": [], "refusals": [], "latency_s": latency,
        "judge": {"verdict": "correct" if matched else "wrong", "reason": ""},
        "score": {"root_cause_matched": matched, "matched": matched and cited, "change_ref_cited": cited},
    }


def test_summary_counts():
    runs = [_run(1, CAUSE, True, 30), _run(1, CAUSE, True, 50), _run(1, CAUSE, False, 70)]
    s = summarize([{"batch": 1, "n": 3, "results": runs}], model_temperature=1.0, model_id="claude-x",
                  now=datetime(2026, 11, 5, tzinfo=UTC))
    assert s["n"] == 3 and s["root_cause_matched"] == 2 and s["matched"] == 2
    assert s["judge"] == {"correct": 2, "partial": 0, "wrong": 1}
    assert s["latency_p50_s"] == 50 and s["latency_p95_s"] == 70
    assert s["pii_blocks"] == 0 and s["refusals"] == 0 and s["ts"] == "2026-11-05T00:00:00Z"
    for key in ("n", "root_cause_matched", "matched", "incidents", "runs_per_incident", "model_temperature",
                "model_id", "per_incident", "judge", "holmes_failed", "bad_output", "pii_blocks", "refusals",
                "threshold_used", "latency_p50_s", "latency_p95_s", "ts"):
        assert key in s, key


def test_summary_records_incident_structure():
    other = "d" * 40
    batches = [
        {"batch": 1, "n": 2, "results": [_run(1, CAUSE, True), _run(1, CAUSE, True)]},
        {"batch": 2, "n": 2, "results": [_run(2, other, True), _run(2, other, False)]},
    ]
    s = summarize(batches, model_temperature=1.0, model_id="anthropic/claude-sonnet-5-5")
    assert s["incidents"] == 2 and s["runs_per_incident"] == 2
    assert s["model_temperature"] == 1.0 and s["model_id"] == "anthropic/claude-sonnet-5-5"
    assert s["per_incident"] == [
        {"batch": 1, "cause_sha": CAUSE, "runs": 2, "root_cause_matched": 2},
        {"batch": 2, "cause_sha": other, "runs": 2, "root_cause_matched": 1},
    ]
    assert (s["n"], s["root_cause_matched"]) == (4, 3)


def test_summary_refuses_a_short_batch():
    with pytest.raises(dryrun.SummaryError):
        summarize([{"batch": 1, "n": 3, "results": [_run(1, CAUSE, True)]}], model_temperature=1.0, model_id="m")


def test_ablation_writes_no_summary(tmp_path):
    run_dir = tmp_path / "run"
    run_dir.mkdir()
    runs = [_run(1, CAUSE, True, cited=False), _run(1, CAUSE, True, cited=False)]
    (run_dir / "batch-1.json").write_text(json.dumps({"batch": 1, "n": 2, "aborted": None, "results": runs}))
    summary, results = tmp_path / "summary.json", tmp_path / "results-ablation.json"
    rc = dryrun.main(["--summarize", str(run_dir), "--batches", "1", "--ablation", "--results-out", str(results),
                      "--summary-out", str(summary)])
    assert rc == 0
    assert not summary.exists()
    assert json.loads(results.read_text())["ablation"] is True
    # If an ablated run still cites the change reference, the delivery-context check is broken.
    runs[0]["score"]["change_ref_cited"] = True
    (run_dir / "batch-1.json").write_text(json.dumps({"batch": 1, "n": 2, "aborted": None, "results": runs}))
    assert dryrun.main(["--summarize", str(run_dir), "--batches", "1", "--ablation",
                        "--results-out", str(results)]) == 1
    assert not summary.exists()


def test_real_summary_written(tmp_path):
    run_dir = tmp_path / "run"
    run_dir.mkdir()
    for b, cause in ((1, CAUSE), (2, "d" * 40)):
        runs = [_run(b, cause, True), _run(b, cause, True)]
        (run_dir / f"batch-{b}.json").write_text(json.dumps({"batch": b, "n": 2, "aborted": None, "results": runs}))
    summary = tmp_path / "summary.json"
    rc = dryrun.main(["--summarize", str(run_dir), "--batches", "2", "--results-out", str(tmp_path / "r.json"),
                      "--summary-out", str(summary), "--model-temperature", "1", "--model-id", "anthropic/x"])
    assert rc == 0
    data = json.loads(summary.read_text())
    assert (data["n"], data["root_cause_matched"], data["incidents"], data["runs_per_incident"]) == (4, 4, 2, 2)
    # a missing batch file refuses
    (run_dir / "batch-2.json").unlink()
    summary.unlink()
    assert dryrun.main(["--summarize", str(run_dir), "--batches", "2", "--results-out", str(tmp_path / "r.json"),
                        "--summary-out", str(summary), "--model-temperature", "1", "--model-id", "x"]) == 1
    assert not summary.exists()


async def test_prompt_uses_the_abort_window(settings):
    holmes = StubHolmes()
    await batch(settings, holmes=holmes, config=cfg(n=1))
    assert "Incident window: 2026-11-05T17:30:00Z to 2026-11-05T17:41:00Z" in holmes.prompts[0]
    assert f"Synced revision: {BUMP}" in holmes.prompts[0]
