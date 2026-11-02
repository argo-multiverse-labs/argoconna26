"""The dry-run harness (Task 6.2): score HolmesGPT's RCA on a frozen, re-armed incident.

    python -m bridge.dryrun --n 5 --app checkout --expected-from-git --batch-id K \\
        --holmes-url http://127.0.0.1:<port> --repo .dryruns/scratch/repo --tracked-ref origin/build/demo \\
        --bump <sha> --change-ref CHG-XXXXXX --abort-at <RFC3339> --threshold 0.7 --out-dir .dryruns/run-<ts>
    python -m bridge.dryrun --summarize .dryruns/run-<ts> --batches K --model-temperature 1 \\
        --model-id <id> --results-out .dryruns/results-<ts>.json [--summary-out .dryruns/summary.json] [--ablation]

`scripts/dry-runs.sh N BATCH` drives it (Δ27): before each batch it disarms, re-arms, waits
for the abort at the new bump revision and for the live bridge to finish with that incident,
then runs one batch against that one frozen incident. This module never re-arms anything.

It runs on the host, from the main checkout, under the cluster lock (P12). Per run it reuses
the bridge's own pipeline up to the rendered output (`pipeline.evaluate_incident`), with:
- a `ReadOnlyForge` that raises on any write, so nothing reaches GitHub;
- a `NullEmitter`, so no dry run can feed a later one through the timeline (P16);
- a fresh `IncidentRegistry` per run (the live one would mark runs 2-n as duplicates).

Rules (each has a test): autonomy on the tracked branch must be `suggest`; before every run
the Application is still Degraded at the frozen revision and the config still holds the armed
value, or the batch aborts and no summary is written; `n` counts attempts, so HolmesGPT
failures stay in the denominator as not matched; every run is scored at the threshold in
force before the batch; a policy-tool error aborts the run instead of scoring
`policy_ok=false`.

Secrets come from the environment only, never from arguments: HOLMES_API_KEY, JUDGE_API_KEY
(the `judge-llm` LiteLLM key) and GITHUB_APP_ID / GITHUB_INSTALLATION_ID / GITHUB_APP_KEY_PATH.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Literal, Protocol

import httpx
import yaml

from .autonomy import read_autonomy
from .config import Settings
from .events import Emitter, NullEmitter, SimChangeRefs
from .forge import AutoMergeResult, CheckStatus, Forge, MergeMethod, PullRequest, PullRequestInfo
from .forge.base import POLICY_CHECK
from .forge.github import GitHubForge
from .github_auth import InstallationTokenProvider
from .guardrails import normalize_value
from .holmes import HolmesClient
from .incidents import IncidentRegistry
from .judge import ChatClient, LiteLLMChat, judge_detail
from .metrics import Metrics
from .models import ArgoDegradedHook
from .pii import PiiHit
from .pipeline import Deps, Evaluation, Holmes, evaluate_incident
from .prompt import live_window
from .score import Expected, score

log = logging.getLogger("bridge.dryrun")

EXIT_DRIFT = 3
EXIT_PRECONDITION = 4
EXIT_POLICY_TOOL = 5
EXIT_EXPECTED = 6
EXIT_USAGE = 2

TRAILER = re.compile(r"^Demo-(?:Rearm|Seed): \S", re.MULTILINE)
SHA = re.compile(r"^[0-9a-f]{40}$")
CHANGE_REF = re.compile(r"^CHG-[A-Z2-7]{6}$")


def _utcnow() -> datetime:
    return datetime.now(UTC)


def _rfc3339(value: datetime) -> str:
    return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


# -- errors ----------------------------------------------------------------------


class DryRunAbort(Exception):
    """The batch stops here and no summary may be written from it."""

    reason = "aborted"
    exit_code = 1


class PreconditionError(DryRunAbort):
    reason, exit_code = "precondition", EXIT_PRECONDITION


class DriftError(DryRunAbort):
    reason, exit_code = "drift", EXIT_DRIFT


class PolicyToolError(DryRunAbort):
    """facts.py or conftest failed, is missing or at the wrong version, or its output doesn't parse."""

    reason, exit_code = "policy_tool_error", EXIT_POLICY_TOOL


class ExpectedError(DryRunAbort):
    """The known answer can't be established (no trailer commit, odd diff, no timeline event)."""

    reason, exit_code = "expected", EXIT_EXPECTED


class ReadOnlyViolation(RuntimeError):
    """Something tried to write through the dry-run forge. Not a ForgeError, so the pipeline's
    'record and go on' path can never swallow it."""


# -- the read-only forge -----------------------------------------------------------


class ReadOnlyForge:
    """Passes every read to `inner`; every write raises `ReadOnlyViolation` (and is recorded)."""

    def __init__(self, inner: Forge) -> None:
        self.inner = inner
        self.attempts: list[str] = []

    def _refuse(self, what: str) -> None:
        self.attempts.append(what)
        raise ReadOnlyViolation(f"dry run: {what} refused (read-only forge)")

    async def read_file(self, path: str, ref: str) -> str:
        return await self.inner.read_file(path, ref)

    async def branch_head(self, branch: str) -> str:
        return await self.inner.branch_head(branch)

    async def resolve_sha(self, sha_or_prefix: str) -> str | None:
        return await self.inner.resolve_sha(sha_or_prefix)

    async def is_ancestor(self, sha: str, ref: str) -> bool:
        return await self.inner.is_ancestor(sha, ref)

    async def commit_changed_key(self, sha: str, path: str, key: str) -> bool:
        return await self.inner.commit_changed_key(sha, path, key)

    async def prs_for_commit(self, sha: str, merged_into: str | None = None) -> list[int]:
        return await self.inner.prs_for_commit(sha, merged_into)

    async def commit_title(self, sha: str) -> str | None:
        return await self.inner.commit_title(sha)

    async def list_open_agent_prs(self, app: str | None = None) -> list[PullRequest]:
        return await self.inner.list_open_agent_prs(app)

    async def list_agent_prs(self, app: str, state: Literal["open", "closed", "all"]) -> list[PullRequestInfo]:
        return await self.inner.list_agent_prs(app, state)

    async def list_pr_comments(self, number: int) -> list[str]:
        return await self.inner.list_pr_comments(number)

    async def merge_methods(self) -> tuple[MergeMethod, ...]:
        return await self.inner.merge_methods()

    async def check_run_status(self, sha: str, name: str = POLICY_CHECK) -> CheckStatus:
        return await self.inner.check_run_status(sha, name)

    async def pr_merged(self, number: int) -> bool:
        return await self.inner.pr_merged(number)

    async def comment_on_commit(self, sha: str, body: str) -> str:
        self._refuse("comment_on_commit")
        raise AssertionError  # unreachable

    async def comment_on_pr(self, number: int, body: str) -> str:
        self._refuse("comment_on_pr")
        raise AssertionError

    async def open_pr(self, base: str, branch: str, title: str, body: str, changes: dict[str, str],
                      commit_message: str, base_sha: str | None = None) -> PullRequest:
        self._refuse("open_pr")
        raise AssertionError

    async def enable_auto_merge(self, pr: PullRequest, method: MergeMethod) -> AutoMergeResult:
        self._refuse("enable_auto_merge")
        raise AssertionError

    async def merge_pr(self, pr: PullRequest, method: MergeMethod) -> str:
        self._refuse("merge_pr")
        raise AssertionError


# -- git -------------------------------------------------------------------------


def _git(repo: Path, *args: str, check: bool = True, env: dict[str, str] | None = None) -> str:
    proc = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, env=env, check=False)
    if check and proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, ["git", *args[:2]], proc.stdout, proc.stderr)
    return proc.stdout


def _configmap_data(text: str) -> dict[str, Any]:
    for doc in yaml.safe_load_all(text):
        if isinstance(doc, dict) and doc.get("kind") == "ConfigMap" and isinstance(doc.get("data"), dict):
            return doc["data"]
    return {}


def expected_from_git(repo: Path, ref: str, change_ref: str) -> Expected:
    """The incident's answer from Git: the newest commit on `ref` with a `Demo-Rearm:` or
    `Demo-Seed:` trailer is the cause; its one changed file, its one changed ConfigMap key,
    and the key's value before (`to_value`, what a fix restores) and after (`from_value`)."""
    if not CHANGE_REF.match(change_ref):
        raise ExpectedError(f"change_ref {change_ref!r} is not a CHG- reference")
    try:
        log_out = _git(repo, "log", "--first-parent", "--format=%H%x1f%B%x1e", ref)
    except subprocess.CalledProcessError as exc:
        raise ExpectedError(f"git log {ref} failed") from exc
    cause = next(
        (sha.strip() for sha, _, body in (e.partition("\x1f") for e in log_out.split("\x1e"))
         if sha.strip() and TRAILER.search(body)),
        None,
    )
    if cause is None:
        raise ExpectedError(f"no commit with a Demo-Rearm: or Demo-Seed: trailer on {ref}")
    files = [f for f in _git(repo, "diff-tree", "--no-commit-id", "--name-only", "-r", cause).splitlines() if f]
    if len(files) != 1:
        raise ExpectedError(f"cause {cause[:7]} changed {len(files)} files, expected 1")
    path = files[0]
    try:
        after = _configmap_data(_git(repo, "show", f"{cause}:{path}"))
        before = _configmap_data(_git(repo, "show", f"{cause}^:{path}"))
    except (subprocess.CalledProcessError, yaml.YAMLError) as exc:
        raise ExpectedError(f"cannot read {path} around {cause[:7]}") from exc
    changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
    if len(changed) != 1 or changed[0] not in before or changed[0] not in after:
        raise ExpectedError(f"cause {cause[:7]} changed keys {changed}, expected one existing key")
    key = changed[0]
    return Expected(cause_sha=cause, file=path, key=key, from_value=normalize_value(after[key]),
                    to_value=normalize_value(before[key]), change_ref=change_ref)


# -- policy_ok -------------------------------------------------------------------


class PolicyCheck(Protocol):
    def check(self, base_sha: str, files: dict[str, str], body: str, commit_message: str) -> bool: ...


class GitPolicy:
    """`policy_ok`: the fix as a temporary commit in a scratch clone (never pushed), then
    `facts.py` and `conftest test --namespace autofix` on it, as the required check would.

    Any tool failure raises `PolicyToolError`; only a parsed conftest result decides the bool.
    """

    def __init__(self, scratch: Path, policy_dir: Path, tracked_ref: str, bot_login: str,
                 conftest_version: str, *, facts: Path | None = None, python: str = sys.executable,
                 conftest: str = "conftest") -> None:
        self.scratch = scratch
        self.policy_dir = policy_dir
        self.facts = facts or policy_dir / "facts" / "facts.py"
        self.tracked_ref = tracked_ref
        self.bot_login = bot_login
        self.conftest_version = conftest_version.lstrip("v")
        self.python = python
        self.conftest = conftest

    def version_check(self) -> None:
        exe = shutil.which(self.conftest)
        if exe is None:
            raise PolicyToolError("conftest not found")
        proc = subprocess.run([exe, "--version"], capture_output=True, text=True, check=False)
        m = re.search(r"Conftest:\s*v?(\S+)", proc.stdout)
        if proc.returncode != 0 or not m or m.group(1) != self.conftest_version:
            raise PolicyToolError(f"conftest is not at {self.conftest_version}")

    def check(self, base_sha: str, files: dict[str, str], body: str, commit_message: str) -> bool:
        self.version_check()
        env = {**os.environ, "GIT_AUTHOR_NAME": "dry-run", "GIT_AUTHOR_EMAIL": "dry-run@example.invalid",
               "GIT_COMMITTER_NAME": "dry-run", "GIT_COMMITTER_EMAIL": "dry-run@example.invalid"}
        try:
            _git(self.scratch, "checkout", "--quiet", "--detach", "--force", base_sha)
            for path, text in files.items():
                target = self.scratch / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text)
            _git(self.scratch, "add", "--", *files)
            _git(self.scratch, "commit", "--quiet", "-m", commit_message, env=env)
            head = _git(self.scratch, "rev-parse", "HEAD").strip()
        except (subprocess.CalledProcessError, OSError) as exc:
            raise PolicyToolError("could not write the temporary fix commit") from exc
        try:
            return self._evaluate(base_sha, head, body)
        finally:
            _git(self.scratch, "checkout", "--quiet", "--detach", "--force", base_sha, check=False)

    def _evaluate(self, base: str, head: str, body: str) -> bool:
        with tempfile.TemporaryDirectory(prefix="dryrun-policy-") as tmp:
            body_file, facts_file = Path(tmp) / "body.md", Path(tmp) / "facts.json"
            body_file.write_text(body)
            facts = subprocess.run(
                [self.python, str(self.facts), "--repo", str(self.scratch), "--base", base, "--head", head,
                 "--body-file", str(body_file), "--author-login", self.bot_login, "--author-type", "Bot",
                 "--tracked-ref", self.tracked_ref],
                capture_output=True, text=True, check=False,
            )
            if facts.returncode != 0:
                raise PolicyToolError(f"facts.py exited {facts.returncode}")
            facts_file.write_text(facts.stdout)
            proc = subprocess.run(
                [self.conftest, "test", str(facts_file), "--policy", str(self.policy_dir), "--namespace",
                 "autofix", "-d", str(self.policy_dir / "data"), "--output", "json", "--no-color"],
                capture_output=True, text=True, check=False,
            )
        try:
            results = json.loads(proc.stdout)
            failures = sum(len(r.get("failures") or []) for r in results)
            tested = sum(int(r.get("successes", 0)) + len(r.get("failures") or []) for r in results)
        except (ValueError, TypeError, AttributeError) as exc:
            raise PolicyToolError("conftest output does not parse") from exc
        if proc.returncode not in (0, 1) or (proc.returncode == 1) != (failures > 0) or tested == 0:
            raise PolicyToolError(f"conftest exited {proc.returncode} with {failures} failures")
        return failures == 0


# -- the cluster -------------------------------------------------------------------


class ClusterView(Protocol):
    async def application(self, app: str) -> dict[str, Any]: ...


class KubectlCluster:
    """Reads the Argo CD Application through kubectl, pinned to the demo's isolated kubeconfig
    and context (Global Constraints). Read-only."""

    def __init__(self, context: str, namespace: str = "argocd", kubeconfig_rel: str = ".kube/argoconna26.yaml",
                 kubectl: str = "kubectl") -> None:
        kubeconfig = os.environ.get("KUBECONFIG", "")
        if not kubeconfig.endswith("/" + kubeconfig_rel.lstrip("/")):
            raise PreconditionError("KUBECONFIG is not the isolated demo kubeconfig")
        self.context = context
        self.namespace = namespace
        self.kubectl = kubectl

    async def application(self, app: str) -> dict[str, Any]:
        proc = await asyncio.create_subprocess_exec(
            self.kubectl, "--context", self.context, "-n", self.namespace, "get", "application", app, "-o", "json",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        out, _ = await proc.communicate()
        if proc.returncode != 0:
            raise DriftError(f"cannot read Application {app}")
        return json.loads(out)


def hook_from_application(app: str, data: dict[str, Any]) -> ArgoDegradedHook:
    """What the Notifications template would send for this Application (Task 3.10)."""
    status, spec = data.get("status") or {}, data.get("spec") or {}
    source = spec.get("source") or {}
    return ArgoDegradedHook.model_validate({
        "app": app,
        "namespace": (spec.get("destination") or {}).get("namespace", ""),
        "revision": ((status.get("operationState") or {}).get("syncResult") or {}).get("revision"),
        "sync_revision": (status.get("sync") or {}).get("revision"),
        "health": (status.get("health") or {}).get("status", ""),
        "history": status.get("history") or [],
        "repo_url": source.get("repoURL", ""),
        "target_revision": source.get("targetRevision", ""),
    })


# -- the timeline ------------------------------------------------------------------


class Timeline(Protocol):
    async def has_change(self, app: str, sha: str, change_ref: str) -> bool: ...


class SimTimeline:
    """`GET /timeline` on cdevents-sim, the same view HolmesGPT gets."""

    def __init__(self, sim_url: str, *, http: httpx.AsyncClient) -> None:
        self.sim_url = sim_url.rstrip("/")
        self._http = http

    async def has_change(self, app: str, sha: str, change_ref: str) -> bool:
        r = await self._http.get(f"{self.sim_url}/timeline", params={"app": app, "since": "-72h", "limit": 1000})
        r.raise_for_status()
        rows = r.json()
        return isinstance(rows, list) and any(
            isinstance(row, dict) and str(row.get("revision", "")).lower() == sha.lower()
            and isinstance(row.get("customData"), dict) and row["customData"].get("change_ref") == change_ref
            for row in rows
        )


# -- one batch ---------------------------------------------------------------------


@dataclass(frozen=True)
class BatchConfig:
    app: str
    batch_id: int
    n: int
    bump: str
    abort_at: datetime
    threshold: float
    armed_value: str
    config_file: str
    config_key: str


def evidence_bundle(expected: Expected, cfg: BatchConfig, tool_calls: Sequence[str]) -> str:
    """The judge's view of the incident: the known answer and the facts the harness holds."""
    calls = ", ".join(tool_calls) or "(none)"
    return "\n".join([
        (f"- Application `{cfg.app}` went Degraded; the canary for revision {cfg.bump} aborted at "
         f"{_rfc3339(cfg.abort_at)}."),
        (f"- The cause is commit {expected.cause_sha} (change reference {expected.change_ref}). It set "
         f"`{expected.key}` in `{expected.file}` from {expected.to_value} to {expected.from_value} and did not "
         "bump the config-version annotation, so only pods started after it read the new value."),
        f"- The right fix restores `{expected.key}` to {expected.to_value}.",
        f"- The investigation's tool calls: {calls}.",
    ])


def _percentile(values: Sequence[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[max(0, math.ceil(pct / 100 * len(ordered)) - 1)], 1)


async def _check_drift(cfg: BatchConfig, cluster: ClusterView, forge: Forge, tracked_branch: str,
                       frozen: str) -> dict[str, Any]:
    data = await cluster.application(cfg.app)
    status = data.get("status") or {}
    health = (status.get("health") or {}).get("status")
    revision = (status.get("sync") or {}).get("revision")
    if health != "Degraded" or revision != frozen:
        raise DriftError(f"Application is {health} at {str(revision)[:7]}, not Degraded at {frozen[:7]}")
    try:
        value = _configmap_data(await forge.read_file(cfg.config_file, tracked_branch)).get(cfg.config_key)
    except Exception as exc:  # unreadable is drift too
        raise DriftError(f"cannot read {cfg.config_file} on {tracked_branch}") from exc
    if value is None or normalize_value(value) != cfg.armed_value:
        raise DriftError(f"{cfg.config_file} on {tracked_branch} no longer holds the armed value")
    return data


async def run_batch(
    cfg: BatchConfig,
    expected: Expected,
    *,
    forge: Forge,
    holmes: Holmes,
    cluster: ClusterView,
    timeline: Timeline,
    policy: PolicyCheck,
    judge_client: ChatClient,
    settings: Settings,
    emitter: Emitter | None = None,
    registry_factory: Callable[[], IncidentRegistry] = IncidentRegistry,
    change_refs: Any = None,
    clock: Callable[[], datetime] = _utcnow,
    on_result: Callable[[dict[str, Any]], None] | None = None,
) -> list[dict[str, Any]]:
    """Run `cfg.n` investigations of one frozen incident and score each. Raises `DryRunAbort`
    (after `on_result` has seen the runs so far) on a precondition, drift or tool failure."""
    # The threshold in force before the batch, fixed for every run in it.
    settings = settings.model_copy(update={"confidence_threshold": cfg.threshold})
    tracked = settings.tracked_branch
    readonly = forge if isinstance(forge, ReadOnlyForge) else ReadOnlyForge(forge)

    autonomy, failsafe = await read_autonomy(readonly, tracked)
    if failsafe is not None or autonomy.level != "suggest":
        raise PreconditionError(
            f"autonomy on {tracked} is {failsafe or autonomy.level}; dry runs need suggest"
        )
    if not await timeline.has_change(cfg.app, expected.cause_sha, expected.change_ref):
        raise ExpectedError(f"/timeline has no change event for {expected.cause_sha[:7]} with {expected.change_ref}")

    first = await cluster.application(cfg.app)
    status = first.get("status") or {}
    frozen = (status.get("sync") or {}).get("revision") or ""
    synced = ((status.get("operationState") or {}).get("syncResult") or {}).get("revision")
    if synced != cfg.bump:
        raise DriftError(f"the last sync is {str(synced)[:7]}, not the bump {cfg.bump[:7]}")
    window = live_window(cfg.abort_at)
    results: list[dict[str, Any]] = []
    for i in range(1, cfg.n + 1):
        data = await _check_drift(cfg, cluster, readonly, tracked, frozen)
        hook = hook_from_application(cfg.app, data)
        hook.received_at = cfg.abort_at
        deps = Deps(
            forge=readonly, holmes=holmes, emitter=emitter or NullEmitter(), settings=settings,
            registry=registry_factory(), clock=clock, metrics=Metrics(), change_refs=change_refs,
        )
        started = clock()
        ev: Evaluation = await evaluate_incident(hook, deps, window)
        elapsed = (clock() - started).total_seconds()
        policy_ok = False
        if ev.fix is not None and ev.fix_texts is not None and ev.fix_base_sha:
            policy_ok = policy.check(ev.fix_base_sha, ev.fix.files, ev.fix_texts.body,
                                     ev.fix_texts.commit_message)
        hits = [PiiHit(kind, (0, len(text))) for kind, text in sorted(ev.pii)]
        verdict = await judge_detail(ev.rca, evidence_bundle(expected, cfg, ev.tool_calls), judge_client)
        s = score(ev.rca, ev.tool_calls, expected, ev.refusals, hits, policy_ok)
        record = {
            "batch": cfg.batch_id,
            "run": i,
            "started_at": _rfc3339(started),
            "seconds_since_abort": round((started - cfg.abort_at).total_seconds(), 1),
            "cause_sha": expected.cause_sha,
            "change_ref": expected.change_ref,
            "bump": cfg.bump,
            "holmes_failed": ev.holmes_failed == "timeout",
            "bad_output": ev.holmes_failed == "bad_output",
            "rca": ev.raw_rca.model_dump(by_alias=True) if ev.raw_rca else None,
            "normalized_cause_sha": ev.rca.cause_commit_sha if ev.rca else None,
            "confidence": ev.raw_rca.confidence if ev.raw_rca else None,
            "tool_calls": list(ev.tool_calls),
            "refusals": [{"reason": r.reason, "detail": r.detail} for r in ev.refusals],
            "pii_kinds": sorted({kind for kind, _ in ev.pii}),  # never the matched text
            "score": asdict(s),
            "judge": {"verdict": verdict.verdict, "reason": verdict.reason},
            "latency_s": round(ev.latency_s if ev.latency_s > 0 else elapsed, 1),
            "threshold_used": cfg.threshold,
        }
        results.append(record)
        if on_result:
            on_result(record)
    return results


# -- the summary -------------------------------------------------------------------


class SummaryError(Exception):
    pass


def summarize(batches: Sequence[dict[str, Any]], *, model_temperature: float | None, model_id: str,
              now: datetime | None = None) -> dict[str, Any]:
    """The summary the slide and panel 4 use (Δ27). Refuses aborted or empty batches."""
    if not batches:
        raise SummaryError("no batches")
    for b in batches:
        if b.get("aborted"):
            raise SummaryError(f"batch {b.get('batch')} aborted ({b['aborted']}); no summary")
    runs = [r for b in batches for r in b.get("results", [])]
    if any(len(b.get("results", [])) != b.get("n") for b in batches):
        raise SummaryError("a batch has fewer results than runs")
    if not runs:
        raise SummaryError("no runs")
    thresholds = {r["threshold_used"] for r in runs}
    if len(thresholds) != 1:
        raise SummaryError(f"runs were scored at different thresholds: {sorted(thresholds)}")

    per_incident: dict[str, dict[str, Any]] = {}
    for b in batches:
        for r in b["results"]:
            row = per_incident.setdefault(r["cause_sha"], {"batch": b["batch"], "cause_sha": r["cause_sha"],
                                                           "runs": 0, "root_cause_matched": 0})
            row["runs"] += 1
            row["root_cause_matched"] += bool(r["score"]["root_cause_matched"])
    counts = {row["runs"] for row in per_incident.values()}
    judge = Counter(r["judge"]["verdict"] for r in runs)
    latencies = [float(r["latency_s"]) for r in runs if r.get("latency_s") is not None]
    return {
        "n": len(runs),
        "root_cause_matched": sum(bool(r["score"]["root_cause_matched"]) for r in runs),
        "matched": sum(bool(r["score"]["matched"]) for r in runs),
        "incidents": len(per_incident),
        "runs_per_incident": counts.pop() if len(counts) == 1 else None,
        "model_temperature": model_temperature,
        "model_id": model_id,
        "per_incident": list(per_incident.values()),
        "judge": {v: judge.get(v, 0) for v in ("correct", "partial", "wrong")},
        "holmes_failed": sum(bool(r["holmes_failed"]) for r in runs),
        "bad_output": sum(bool(r["bad_output"]) for r in runs),
        "pii_blocks": sum(bool(r["pii_kinds"]) for r in runs),
        "refusals": sum(bool(r["refusals"]) for r in runs),
        "change_ref_cited": sum(bool(r["score"]["change_ref_cited"]) for r in runs),
        "threshold_used": thresholds.pop(),
        "latency_p50_s": _percentile(latencies, 50),
        "latency_p95_s": _percentile(latencies, 95),
        "ts": _rfc3339(now or _utcnow()),
    }


def load_batches(run_dir: Path, expected_batches: int) -> list[dict[str, Any]]:
    files = sorted(run_dir.glob("batch-*.json"), key=lambda p: int(p.stem.split("-")[1]))
    if len(files) != expected_batches:
        raise SummaryError(f"{len(files)} batch files in {run_dir}, expected {expected_batches}")
    return [json.loads(p.read_text()) for p in files]


def write_outputs(run_dir: Path, expected_batches: int, *, results_out: Path, summary_out: Path | None,
                  model_temperature: float | None, model_id: str, ablation: bool = False) -> dict[str, Any]:
    """Write the combined results; write `summary.json` only for a real (not ablation) run.

    An ablation run (Δ28: the timeline toolset disabled) never writes a summary, so it can't
    reach the slide or panel 4. Its check is that no run cited the change reference."""
    batches = load_batches(run_dir, expected_batches)
    for b in batches:
        if b.get("aborted"):
            raise SummaryError(f"batch {b.get('batch')} aborted ({b['aborted']}); no summary")
    runs = [r for b in batches for r in b.get("results", [])]
    results_out.parent.mkdir(parents=True, exist_ok=True)
    results_out.write_text(json.dumps({"ablation": ablation, "runs": runs}, indent=2) + "\n")
    if ablation:
        return {"ablation": True, "n": len(runs),
                "change_ref_cited": sum(bool(r["score"]["change_ref_cited"]) for r in runs)}
    summary = summarize(batches, model_temperature=model_temperature, model_id=model_id)
    if summary_out is None:
        raise SummaryError("no --summary-out for a real run")
    tmp = summary_out.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(summary, indent=2) + "\n")
    tmp.replace(summary_out)
    return summary


# -- the command line ----------------------------------------------------------------


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="python -m bridge.dryrun", description=__doc__.split("\n\n")[0])
    p.add_argument("--summarize", type=Path, metavar="RUN_DIR", help="combine a run's batch files")
    p.add_argument("--batches", type=int)
    p.add_argument("--model-temperature", type=float)
    p.add_argument("--model-id", default="")
    p.add_argument("--results-out", type=Path)
    p.add_argument("--summary-out", type=Path)
    p.add_argument("--ablation", action="store_true")
    p.add_argument("--n", type=int)
    p.add_argument("--app", default="checkout")
    p.add_argument("--expected-from-git", action="store_true")
    p.add_argument("--batch-id", type=int)
    p.add_argument("--holmes-url")
    p.add_argument("--repo", type=Path, help="the scratch clone (expected cause, policy_ok)")
    p.add_argument("--tracked-ref", help="the tracked branch in the scratch clone, e.g. origin/build/demo")
    p.add_argument("--bump")
    p.add_argument("--change-ref")
    p.add_argument("--abort-at")
    p.add_argument("--threshold", type=float)
    p.add_argument("--out-dir", type=Path)
    p.add_argument("--sim-url", default="http://127.0.0.1:30082")
    p.add_argument("--litellm-url", default="http://127.0.0.1:30400/v1")
    p.add_argument("--policy-dir", type=Path)
    p.add_argument("--conftest-version", default=os.environ.get("CONFTEST_VERSION", ""))
    p.add_argument("--kube-context", default=os.environ.get("CLUSTER_CONTEXT", "kind-argoconna26"))
    return p


def _summarize_main(args: argparse.Namespace) -> int:
    if args.batches is None or args.results_out is None or (not args.ablation and args.summary_out is None):
        print("--summarize needs --batches, --results-out and (unless --ablation) --summary-out", file=sys.stderr)
        return EXIT_USAGE
    if not args.ablation and not args.model_id:
        print("--model-id is required for a real run", file=sys.stderr)
        return EXIT_USAGE
    try:
        out = write_outputs(args.summarize, args.batches, results_out=args.results_out,
                            summary_out=None if args.ablation else args.summary_out,
                            model_temperature=args.model_temperature, model_id=args.model_id,
                            ablation=args.ablation)
    except (SummaryError, OSError, ValueError, KeyError) as exc:
        print(f"dry-run summary refused: {exc}", file=sys.stderr)
        return 1
    if args.ablation:
        print(f"ablation: {out['change_ref_cited']}/{out['n']} runs cited the change reference")
        return 0 if out["change_ref_cited"] == 0 else 1
    print(f"dry runs: {out['root_cause_matched']}/{out['n']} matched the root cause "
          f"({out['matched']} on every check) across {out['incidents']} incidents")
    return 0


async def _batch_main(args: argparse.Namespace) -> int:
    required = ("n", "batch_id", "holmes_url", "repo", "tracked_ref", "bump", "change_ref", "abort_at",
                "threshold", "out_dir", "policy_dir")
    missing = [f"--{r.replace('_', '-')}" for r in required if getattr(args, r) in (None, "")]
    if missing or not args.expected_from_git:
        print(f"missing: {' '.join(missing) or '--expected-from-git'}", file=sys.stderr)
        return EXIT_USAGE
    if not SHA.match(args.bump):
        print("--bump must be a full SHA", file=sys.stderr)
        return EXIT_USAGE
    env_missing = [k for k in ("HOLMES_API_KEY", "JUDGE_API_KEY", "GITHUB_APP_ID", "GITHUB_INSTALLATION_ID",
                               "GITHUB_APP_KEY_PATH") if not os.environ.get(k)]
    if env_missing:
        print(f"missing in the environment: {' '.join(env_missing)}", file=sys.stderr)
        return EXIT_USAGE

    settings = Settings()
    abort_at = datetime.fromisoformat(args.abort_at)
    out_dir: Path = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    batch_file = out_dir / f"batch-{args.batch_id}.json"
    results: list[dict[str, Any]] = []
    batch: dict[str, Any] = {"batch": args.batch_id, "n": args.n, "aborted": None, "results": results}

    def save() -> None:
        tmp = batch_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(batch, indent=2) + "\n")
        tmp.replace(batch_file)

    def keep(record: dict[str, Any]) -> None:
        results.append(record)
        save()

    try:
        expected = expected_from_git(args.repo, args.tracked_ref, args.change_ref)
        cfg = BatchConfig(app=args.app, batch_id=args.batch_id, n=args.n, bump=args.bump, abort_at=abort_at,
                          threshold=args.threshold, armed_value=expected.from_value, config_file=expected.file,
                          config_key=expected.key)
        batch.update({"cause_sha": expected.cause_sha, "change_ref": expected.change_ref, "bump": args.bump,
                      "abort_at": _rfc3339(abort_at), "threshold_used": args.threshold})
        policy = GitPolicy(args.repo, args.policy_dir, args.tracked_ref, settings.bot_login, args.conftest_version)
        policy.version_check()
        cluster = KubectlCluster(args.kube_context, os.environ.get("NS_ARGOCD", "argocd"),
                                 os.environ.get("KUBECONFIG_REL", ".kube/argoconna26.yaml"))
        async with httpx.AsyncClient(timeout=30.0) as http:
            provider = InstallationTokenProvider(
                os.environ["GITHUB_APP_ID"], os.environ["GITHUB_INSTALLATION_ID"],
                os.environ["GITHUB_APP_KEY_PATH"], repo=settings.github_repo, http=http,
            )
            forge = ReadOnlyForge(GitHubForge(settings.github_repo, provider, api_url=settings.github_api_url,
                                              http=http, bot_login=settings.bot_login))
            holmes = HolmesClient(args.holmes_url, os.environ["HOLMES_API_KEY"], settings.holmes_model,
                                  settings.holmes_timeout_s, http=http)
            await run_batch(
                cfg, expected, forge=forge, holmes=holmes, cluster=cluster,
                timeline=SimTimeline(args.sim_url, http=http), policy=policy,
                judge_client=LiteLLMChat(args.litellm_url, os.environ["JUDGE_API_KEY"], http=http),
                settings=settings, change_refs=SimChangeRefs(f"{args.sim_url.rstrip('/')}/events", http=http),
                on_result=keep,
            )
    except DryRunAbort as exc:
        batch["aborted"] = exc.reason
        batch["detail"] = str(exc)
        save()
        print(f"dry-run batch {args.batch_id} aborted ({exc.reason}): {exc}", file=sys.stderr)
        return exc.exit_code
    except ReadOnlyViolation as exc:
        batch["aborted"] = "write_attempted"
        save()
        print(f"dry-run batch {args.batch_id}: {exc}", file=sys.stderr)
        return 1
    save()
    matched = sum(bool(r["score"]["root_cause_matched"]) for r in results)
    print(f"batch {args.batch_id}: {matched}/{len(results)} matched the root cause")
    return 0


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(name)s: %(message)s")
    args = _parser().parse_args(argv)
    if args.summarize is not None:
        return _summarize_main(args)
    return asyncio.run(_batch_main(args))


if __name__ == "__main__":
    sys.exit(main())
