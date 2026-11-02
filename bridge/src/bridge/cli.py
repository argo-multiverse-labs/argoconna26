"""e2e harness commands. Not part of the running bridge; never imported by the app.

    python -m bridge.cli try-direct-push [--repo OWNER/NAME] [--branches a,b] [--operator-ref REF]
    python -m bridge.cli spike-pr --base rehearse/merge-spike --scenario two-line [--repo OWNER/NAME]
    python -m bridge.cli open-test-pr --scenario <name> [--base BRANCH]      (tests/e2e/policy-negative.sh only)
    python -m bridge.cli test-pr-try-merge --pr N [--rest]                   (tests/e2e/policy-negative.sh only)

`try-direct-push` proves, with the App's own installation token, that the standing rulesets hold:
for each protected branch it creates (through the Git Data API) a commit whose parent is the
branch head and whose tree is the head's tree, tries to move the branch ref to it, then tries to
delete the ref. It also tries to create `promote/app-test-<stamp>` and, when the operator has
pushed a promotion branch, to move and then delete that. Every attempt must get a 4xx whose
message names a repository rule violation (or, for a delete of the default branch, GitHub's own
default-branch guard, counted separately). A success, or a 4xx for any other reason, fails the
check.

A success is undone where the App can undo it: a deleted ref is re-created at its old sha and a
stray `promote/*` ref is deleted. A *move* of a branch under the integrity ruleset cannot be undone
by anyone (moving it back is a force-push, and that ruleset has no bypass), so it leaves one probe
commit on the branch. The probe has the same tree as its parent, so it changes no file; removing
it means unlisting the branch from the integrity ruleset first. The check prints that step.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import os
import re
import sys
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote

import httpx

from .github_auth import InstallationTokenProvider

_RULESET_MSG = re.compile(r"repository rule violation|argoconna26-", re.IGNORECASE)
_API = "https://api.github.com"
# GitHub refuses a delete of the default branch before any ruleset is consulted.
_DEFAULT_GUARD = re.compile(r"cannot delete the default branch", re.IGNORECASE)
# The Git Data API gives no rule text when a ruleset blocks a ref creation.
_GENERIC_CREATE = re.compile(r"reference update failed", re.IGNORECASE)


@dataclass
class AttemptResult:
    target: str
    action: str  # move | delete | create
    status: int | None
    ok: bool
    detail: str
    refused_by: str = ""  # "ruleset" | "default-branch guard" | "" (not refused)


class _Gh:
    def __init__(self, http: httpx.AsyncClient, tokens: Any, repo: str, api_url: str) -> None:
        self.http, self.tokens, self.repo, self.api = http, tokens, repo, api_url.rstrip("/")

    async def call(self, method: str, path: str, **kw: Any) -> httpx.Response:
        headers = {
            "Authorization": f"Bearer {await self.tokens.token()}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        return await self.http.request(method, f"{self.api}/repos/{self.repo}{path}", headers=headers, **kw)

    async def head(self, branch: str) -> str:
        r = await self.call("GET", f"/git/ref/heads/{quote(branch, safe='/')}")
        r.raise_for_status()
        return str(r.json()["object"]["sha"])

    async def unreachable_child(self, parent: str) -> str:
        c = await self.call("GET", f"/git/commits/{parent}")
        c.raise_for_status()
        tree = c.json()["tree"]["sha"]
        n = await self.call(
            "POST", "/git/commits", json={"message": "rehearsal: direct-push probe", "tree": tree, "parents": [parent]}
        )
        n.raise_for_status()
        return str(n.json()["sha"])


def _message(r: httpx.Response) -> str:
    try:
        return str(r.json().get("message", ""))[:160].replace("\n", " ")
    except ValueError:
        return ""


def _verdict(target: str, action: str, r: httpx.Response) -> AttemptResult:
    msg = _message(r)
    refused = 400 <= r.status_code < 500
    named = bool(_RULESET_MSG.search(msg))
    if refused and named:
        return AttemptResult(target, action, r.status_code, True, f"refused: {msg}", "ruleset")
    if refused and action == "delete" and _DEFAULT_GUARD.search(msg):
        return AttemptResult(target, action, r.status_code, True,
                             f"refused by the default-branch guard (not a ruleset message): {msg}",
                             "default-branch guard")
    if refused:
        return AttemptResult(target, action, r.status_code, False, f"4xx for another reason: {msg}")
    return AttemptResult(target, action, r.status_code, False, "SUCCEEDED (should have been refused)")


async def run_try_direct_push(
    http: httpx.AsyncClient,
    tokens: Any,
    *,
    repo: str,
    branches: list[str],
    operator_ref: str | None = None,
    api_url: str = _API,
    stamp: str | None = None,
) -> list[AttemptResult]:
    gh = _Gh(http, tokens, repo, api_url)
    stamp = stamp or str(int(time.time()))
    results: list[AttemptResult] = []

    async def move(target: str, old: str, new: str) -> None:
        ref = f"/git/refs/heads/{quote(target, safe='/')}"
        r = await gh.call("PATCH", ref, json={"sha": new, "force": False})
        v = _verdict(target, "move", r)
        if not v.ok and r.status_code < 300:
            back = await gh.call("PATCH", ref, json={"sha": old, "force": True})
            v.detail += f"; restored={back.status_code < 300}"
            if back.status_code >= 300:
                v.detail += (
                    f"; {target} now carries an empty-tree probe commit (same tree as {old[:12]}, no file"
                    " changed). To remove it, unlist the branch from the integrity ruleset"
                    " (RULESET_BRANCHES, then github-ruleset.sh apply), reset it, and re-list it"
                )
        results.append(v)

    async def delete(target: str, old: str) -> None:
        r = await gh.call("DELETE", f"/git/refs/heads/{quote(target, safe='/')}")
        v = _verdict(target, "delete", r)
        if not v.ok and r.status_code < 300:
            back = await gh.call("POST", "/git/refs", json={"ref": f"refs/heads/{target}", "sha": old})
            v.detail += f"; restored={back.status_code < 300}"
        results.append(v)

    for b in branches:
        old = await gh.head(b)
        new = await gh.unreachable_child(old)
        await move(b, old, new)
        await delete(b, old)

    base = await gh.head(branches[0])
    name = f"promote/app-test-{stamp}"
    r = await gh.call("POST", "/git/refs", json={"ref": f"refs/heads/{name}", "sha": base})
    v = _verdict(name, "create", r)
    if not v.ok and r.status_code < 300:
        await gh.call("DELETE", f"/git/refs/heads/{quote(name, safe='/')}")
        v.detail += "; stray ref deleted"
    elif not v.ok and _GENERIC_CREATE.search(_message(r)):
        # The API words a ruleset block on ref creation generically. Create the same ref under a
        # name no ruleset covers: if that works, the promote/* refusal is the ruleset's doing.
        ctl = f"rehearse/control-{stamp}"
        c = await gh.call("POST", "/git/refs", json={"ref": f"refs/heads/{ctl}", "sha": base})
        if c.status_code < 300:
            await gh.call("DELETE", f"/git/refs/heads/{quote(ctl, safe='/')}")
            v = AttemptResult(name, "create", r.status_code, True,
                              f"refused ('{_message(r)}'); control ref at an unprotected name was created and removed",
                              "ruleset")
        else:
            v.detail += f"; control create also failed ({c.status_code}), so this is not proven to be the ruleset"
    results.append(v)

    if operator_ref:
        old = await gh.head(operator_ref)
        new = await gh.unreachable_child(old)
        await move(operator_ref, old, new)
        await delete(operator_ref, old)
    return results


def summarize(results: list[AttemptResult]) -> str:
    """One line that says who refused what, so a guard refusal is never counted as a ruleset's."""
    by_rule = sum(1 for x in results if x.ok and x.refused_by == "ruleset")
    by_guard = sum(1 for x in results if x.ok and x.refused_by == "default-branch guard")
    bad = sum(1 for x in results if not x.ok)
    line = f"{by_rule + by_guard}/{len(results)} attempts refused: {by_rule} by a ruleset"
    if by_guard:
        line += f", {by_guard} by the default-branch guard"
    if bad:
        line += f"; {bad} FAILED"
    return line


# --- spike-pr: GitHub merge mechanics (Task 4.5a) ---------------------------------------------

SPIKE_BASE = "rehearse/merge-spike"
_SPIKE_FILE = "apps/pricing/README.md"
_REV_LINE = re.compile(r"^(Notes revision: )(\d+)$", re.MULTILINE)
_ENABLE_AUTO_MERGE = (
    "mutation($id: ID!, $method: PullRequestMergeMethod!) {"
    " enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: $method}) {"
    " pullRequest { autoMergeRequest { enabledAt mergeMethod } } } }"
)


class SpikeError(Exception):
    pass


@dataclass
class SpikeResult:
    number: int
    url: str
    branch: str
    auto_merge_enabled: bool
    auto_merge_error: str
    merged: bool
    final_state: str
    mergeable_state: str
    waited_s: float
    branch_deleted: bool = False


async def run_spike_pr(
    http: httpx.AsyncClient,
    tokens: Any,
    *,
    repo: str,
    base: str,
    scenario: str = "two-line",
    api_url: str = _API,
    stamp: str | None = None,
    wait: bool = True,
    timeout_s: float = 600.0,
    poll_s: float = 5.0,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
) -> SpikeResult:
    """Open an App-authored PR that changes one line, enable auto-merge, wait on the PR state.

    Refuses any base but the scratch branch, before any request. Only `two-line` exists
    here; `autonomy-raise` is Task 4.5a Step 2.
    """
    if base != SPIKE_BASE:
        raise SpikeError(f"spike-pr only runs against {SPIKE_BASE}, not {base!r}")
    if scenario != "two-line":
        raise SpikeError(f"scenario {scenario!r} is not implemented here (autonomy-raise is Task 4.5a Step 2)")
    gh = _Gh(http, tokens, repo, api_url)
    stamp = stamp or str(int(time.time()))
    branch = f"agent/spike-{stamp}"

    head = await gh.head(base)
    cur = await gh.call("GET", f"/contents/{_SPIKE_FILE}", params={"ref": base})
    cur.raise_for_status()
    text = base64.b64decode(cur.json()["content"]).decode()
    if not _REV_LINE.search(text):
        raise SpikeError(f"{_SPIKE_FILE} has no 'Notes revision: N' line")
    new_text = _REV_LINE.sub(lambda m: f"{m.group(1)}{int(m.group(2)) + 1}", text, count=1)

    (await gh.call("POST", "/git/refs", json={"ref": f"refs/heads/{branch}", "sha": head})).raise_for_status()
    put = await gh.call(
        "PUT",
        f"/contents/{_SPIKE_FILE}",
        json={
            "message": "spike: bump the notes revision",
            "content": base64.b64encode(new_text.encode()).decode(),
            "sha": cur.json()["sha"],
            "branch": branch,
        },
    )
    put.raise_for_status()
    pr = await gh.call(
        "POST",
        "/pulls",
        json={"title": "spike: bump the notes revision", "head": branch, "base": base,
              "body": "Merge-mechanics spike (Task 4.5a). Scratch branch only."},
    )
    pr.raise_for_status()
    number, node_id, url = pr.json()["number"], pr.json()["node_id"], pr.json().get("html_url", "")

    enabled, err = False, ""
    g = await http.post(
        f"{api_url.rstrip('/')}/graphql",
        headers={"Authorization": f"Bearer {await tokens.token()}", "Accept": "application/vnd.github+json"},
        json={"query": _ENABLE_AUTO_MERGE, "variables": {"id": node_id, "method": "MERGE"}},
    )
    body = g.json() if g.headers.get("content-type", "").startswith("application/json") else {}
    if g.status_code < 300 and not body.get("errors"):
        enabled = True
    else:
        err = "; ".join(e.get("message", "") for e in body.get("errors", [])) or f"HTTP {g.status_code}"

    merged, state, mstate, waited = False, "OPEN", "", 0.0
    while True:
        v = await gh.call("GET", f"/pulls/{number}")
        v.raise_for_status()
        j = v.json()
        merged, state, mstate = bool(j.get("merged")), str(j.get("state", "")).upper(), str(j.get("mergeable_state", ""))
        if merged:
            state = "MERGED"
        if merged or state == "CLOSED" or not wait or waited >= timeout_s:
            break
        await sleep(poll_s)
        waited += poll_s
    # The repo keeps head branches after a merge (delete_branch_on_merge is off), so remove ours
    # once the PR is done; a still-open PR keeps its branch.
    deleted = False
    if state in ("MERGED", "CLOSED"):
        d = await gh.call("DELETE", f"/git/refs/heads/{quote(branch, safe='/')}")
        deleted = d.status_code < 300
    return SpikeResult(number, url, branch, enabled, err, merged, state, mstate, waited, deleted)


# --- open-test-pr / test-pr-try-merge: policy-negative e2e (Task 5.6 Step 2) -----------------

TEST_PR_PREFIX = "agent/test-"
TEST_LABEL = "policy-negative-test"
TEST_PR_BODY = "Opened by the operator with the agent's identity to test the policy; not opened by the agent."
SCENARIOS = ("image-change", "tamper-autofix", "tamper-goldenpath", "tamper-workflow", "tamper-autonomy")

_CONFIG_FILE = os.environ.get("CONFIG_FILE", "apps/checkout/config/checkout-config.yaml")
_ROLLOUT_FILE = os.environ.get("ROLLOUT_FILE", "apps/checkout/deploy/rollout.yaml")
_AUTONOMY_FILE = os.environ.get("AUTONOMY_FILE", "aiops/autonomy.yaml")
_CONFIG_KEY = os.environ.get("CONFIG_KEY", "UPSTREAM_TIMEOUT_MS")
_CONFIG_HEALTHY = os.environ.get("CONFIG_HEALTHY", "2000")
_CONFIG_ARMED = os.environ.get("CONFIG_ARMED", "200")
_KUSTOMIZATION = "apps/checkout/kustomization.yaml"
_PRICING = "apps/pricing/deploy/deployment.yaml"
_WORKFLOW = ".github/workflows/policy.yml"
_AUTOFIX_REGO = "policy/autofix.rego"
_GOLDEN_REGO = "policy/golden_path.rego"
_ALLOW_ALL = "package {pkg}\n\nimport rego.v1\n\n# policy negative test: allow everything\ndeny := set()\n"


class NegativePrError(Exception):
    pass


def negative_branch_name(scenario: str, stamp: str) -> str:
    return f"{TEST_PR_PREFIX}{scenario}-{stamp}"


def _files_for(scenario: str) -> tuple[str, ...]:
    fix = (_CONFIG_FILE, _ROLLOUT_FILE, _KUSTOMIZATION)
    return {
        "image-change": fix,
        "tamper-autofix": (*fix, _AUTOFIX_REGO),
        "tamper-goldenpath": (_PRICING, _GOLDEN_REGO),
        "tamper-workflow": (_WORKFLOW,),
        "tamper-autonomy": (_AUTONOMY_FILE,),
    }[scenario]


def _sub_once(text: str, pattern: str, repl: Callable[[re.Match[str]], str], what: str) -> str:
    new, n = re.subn(pattern, repl, text, count=1, flags=re.MULTILINE)
    if n != 1:
        raise NegativePrError(f"no {what} line to change")
    return new


def _fix_shape_plus_image(files: dict[str, str]) -> dict[str, str]:
    """A fix-shaped change (the key toggled to a value seen before, config-version + 1) plus an
    image tag bump in kustomization.yaml: only autofix rules 1 and 4 can catch it."""
    def flip(m: re.Match[str]) -> str:
        to = _CONFIG_ARMED if m.group(2) == _CONFIG_HEALTHY else _CONFIG_HEALTHY
        return f'{m.group(1)}"{to}"'

    def bump_cv(m: re.Match[str]) -> str:
        return f'{m.group(1)}"{int(m.group(2)) + 1}"'

    def bump_tag(m: re.Match[str]) -> str:
        return f"{m.group(1)}{m.group(2)}{int(m.group(3)) + 1}"

    return {
        _CONFIG_FILE: _sub_once(files[_CONFIG_FILE], rf'^(\s*{re.escape(_CONFIG_KEY)}:\s*)"?(\d+)"?\s*$', flip, _CONFIG_KEY),
        _ROLLOUT_FILE: _sub_once(files[_ROLLOUT_FILE], r'^(\s*example\.dev/config-version:\s*)"?(\d+)"?\s*$',
                                 bump_cv, "config-version"),
        _KUSTOMIZATION: _sub_once(files[_KUSTOMIZATION], r"^(\s*newTag:\s*)(v\d+\.\d+\.)(\d+)\s*$", bump_tag, "newTag"),
    }


def scenario_edits(scenario: str, files: dict[str, str]) -> dict[str, str]:
    """The new content of every file the scenario changes, from the base contents in `files`."""
    if scenario not in SCENARIOS:
        raise NegativePrError(f"unknown scenario {scenario!r} (one of {', '.join(SCENARIOS)})")
    if scenario == "image-change":
        return _fix_shape_plus_image(files)
    if scenario == "tamper-autofix":
        return {**_fix_shape_plus_image(files), _AUTOFIX_REGO: _ALLOW_ALL.format(pkg="autofix")}
    if scenario == "tamper-goldenpath":
        # Drop the workload's own owner label (the first one); the pod template keeps its copy.
        dep = _sub_once(files[_PRICING], r"^\s*example\.dev/owner:.*\n", lambda _m: "", "example.dev/owner")
        return {_PRICING: dep, _GOLDEN_REGO: _ALLOW_ALL.format(pkg="goldenpath")}
    if scenario == "tamper-workflow":
        return {_WORKFLOW: files[_WORKFLOW].rstrip("\n") + "\n# policy negative test: the agent edits the workflow\n"}
    # tamper-autonomy: the agent tries to promote itself.
    if re.search(r"^level:\s*act\s*$", files[_AUTONOMY_FILE], re.MULTILINE):
        raise NegativePrError(f"{_AUTONOMY_FILE} is already at act; nothing to raise")
    return {_AUTONOMY_FILE: _sub_once(files[_AUTONOMY_FILE], r"^level:\s*\S+\s*$", lambda _m: "level: act", "level")}


@dataclass
class NegativePrResult:
    scenario: str
    branch: str
    number: int | None = None
    url: str = ""
    head: str = ""
    refused_status: int | None = None
    refused_message: str = ""
    note: str = ""


async def run_open_test_pr(
    http: httpx.AsyncClient,
    tokens: Any,
    *,
    repo: str,
    base: str,
    scenario: str,
    api_url: str = _API,
    stamp: str | None = None,
    branch: str | None = None,
) -> NegativePrResult:
    """Open an App-authored PR for a policy-negative scenario, labelled TEST_LABEL.

    One commit through the Git Data API on a fresh `agent/test-*` branch. For `tamper-workflow`
    the ref creation is expected to be refused (no `workflows` permission), and no PR is opened.
    """
    if scenario not in SCENARIOS:
        raise NegativePrError(f"unknown scenario {scenario!r} (one of {', '.join(SCENARIOS)})")
    stamp = stamp or str(int(time.time()))
    branch = branch or negative_branch_name(scenario, stamp)
    if not branch.startswith(TEST_PR_PREFIX):
        raise NegativePrError(f"refusing branch {branch!r}: test PRs use {TEST_PR_PREFIX}*")
    gh = _Gh(http, tokens, repo, api_url)
    res = NegativePrResult(scenario, branch)

    head = await gh.head(base)
    c = await gh.call("GET", f"/git/commits/{head}")
    c.raise_for_status()
    base_tree = c.json()["tree"]["sha"]
    files: dict[str, str] = {}
    for path in _files_for(scenario):
        f = await gh.call("GET", f"/contents/{quote(path, safe='/')}", params={"ref": head})
        f.raise_for_status()
        files[path] = base64.b64decode(f.json()["content"]).decode()
    edits = scenario_edits(scenario, files)

    t = await gh.call("POST", "/git/trees", json={
        "base_tree": base_tree,
        "tree": [{"path": p, "mode": "100644", "type": "blob", "content": txt} for p, txt in sorted(edits.items())],
    })
    t.raise_for_status()
    n = await gh.call("POST", "/git/commits", json={
        "message": f"policy negative test: {scenario}", "tree": t.json()["sha"], "parents": [head]})
    n.raise_for_status()
    commit = str(n.json()["sha"])
    r = await gh.call("POST", "/git/refs", json={"ref": f"refs/heads/{branch}", "sha": commit})
    ref_path = f"/git/refs/heads/{quote(branch, safe='/')}"

    if scenario == "tamper-workflow":
        if 400 <= r.status_code < 500:
            res.refused_status, res.refused_message = r.status_code, _message(r)
            left = await gh.call("GET", f"/git/ref/heads/{quote(branch, safe='/')}")
            if left.status_code < 300:
                await gh.call("DELETE", ref_path)
                res.note = "the refused ref existed anyway and was deleted"
        elif r.status_code < 300:
            d = await gh.call("DELETE", ref_path)
            res.note = f"ref creation SUCCEEDED (should have been refused); deleted={d.status_code < 300}"
        else:
            r.raise_for_status()
        return res

    r.raise_for_status()
    res.head = commit
    body = TEST_PR_BODY
    if scenario in ("image-change", "tamper-autofix"):
        lc = await gh.call("GET", "/commits", params={"sha": head, "path": _CONFIG_FILE, "per_page": 1})
        lc.raise_for_status()
        if lc.json():
            body += f"\n\nCause: {lc.json()[0]['sha']}"
    p = await gh.call("POST", "/pulls", json={
        "title": f"[policy negative test] {scenario}", "head": branch, "base": base, "body": body})
    if p.status_code >= 300:
        await gh.call("DELETE", ref_path)
        raise NegativePrError(f"could not open the PR ({p.status_code}: {_message(p)}); branch deleted")
    res.number, res.url = int(p.json()["number"]), str(p.json().get("html_url", ""))
    lab = await gh.call("POST", f"/issues/{res.number}/labels", json={"labels": [TEST_LABEL]})
    if lab.status_code >= 300:
        await gh.call("PATCH", f"/pulls/{res.number}", json={"state": "closed"})
        await gh.call("DELETE", ref_path)
        raise NegativePrError(f"could not label PR {res.number} {TEST_LABEL} ({lab.status_code}); closed it, branch deleted")
    return res


@dataclass
class TryMergeResult:
    number: int
    auto_merge_enabled: bool
    auto_merge_error: str
    rest_status: int | None = None
    rest_message: str = ""


async def run_test_pr_try_merge(
    http: httpx.AsyncClient,
    tokens: Any,
    *,
    repo: str,
    number: int,
    rest: bool,
    api_url: str = _API,
) -> TryMergeResult:
    """With the App token: enable auto-merge (as the bridge does) and, with `rest`, try a REST merge.

    Refuses, before any write, unless the PR is on an `agent/test-*` branch and labelled TEST_LABEL,
    so it can never merge one of the agent's real PRs.
    """
    gh = _Gh(http, tokens, repo, api_url)
    v = await gh.call("GET", f"/pulls/{number}")
    v.raise_for_status()
    pr = v.json()
    ref = str(pr.get("head", {}).get("ref", ""))
    labels = {str(x.get("name")) for x in pr.get("labels", [])}
    if not ref.startswith(TEST_PR_PREFIX) or TEST_LABEL not in labels:
        raise NegativePrError(f"PR {number} is not a {TEST_LABEL} PR on {TEST_PR_PREFIX}* (branch {ref!r})")
    g = await http.post(
        f"{api_url.rstrip('/')}/graphql",
        headers={"Authorization": f"Bearer {await tokens.token()}", "Accept": "application/vnd.github+json"},
        json={"query": _ENABLE_AUTO_MERGE, "variables": {"id": pr["node_id"], "method": "MERGE"}},
    )
    body = g.json() if g.headers.get("content-type", "").startswith("application/json") else {}
    errors = "; ".join(e.get("message", "") for e in body.get("errors", []))
    res = TryMergeResult(number, g.status_code < 300 and not errors, errors or ("" if g.status_code < 300 else f"HTTP {g.status_code}"))
    if rest:
        m = await gh.call("PUT", f"/pulls/{number}/merge", json={"merge_method": "merge", "sha": pr["head"]["sha"]})
        res.rest_status, res.rest_message = m.status_code, _message(m)
    return res


def _print(results: list[AttemptResult]) -> None:
    for x in results:
        print(f"{'ok  ' if x.ok else 'FAIL'} {x.action:<6} {x.target:<28} {x.status} {x.detail}")


async def _try_direct_push(args: argparse.Namespace) -> int:
    for key in ("GITHUB_APP_ID", "GITHUB_INSTALLATION_ID", "GITHUB_APP_KEY_PATH"):
        if not os.environ.get(key):
            print(f"missing {key} (load .env)", file=sys.stderr)
            return 2
    branches = [b for b in args.branches.split(",") if b]
    if not branches:
        print("no branches given", file=sys.stderr)
        return 2
    async with httpx.AsyncClient(timeout=30.0) as http:
        provider = InstallationTokenProvider(
            os.environ["GITHUB_APP_ID"],
            os.environ["GITHUB_INSTALLATION_ID"],
            os.environ["GITHUB_APP_KEY_PATH"],
            repo=args.repo,
            http=http,
        )
        results = await run_try_direct_push(
            http, provider, repo=args.repo, branches=branches, operator_ref=args.operator_ref
        )
    _print(results)
    print(summarize(results))
    return 1 if any(not x.ok for x in results) else 0


async def _spike_pr(args: argparse.Namespace) -> int:
    for key in ("GITHUB_APP_ID", "GITHUB_INSTALLATION_ID", "GITHUB_APP_KEY_PATH"):
        if not os.environ.get(key):
            print(f"missing {key} (load .env)", file=sys.stderr)
            return 2
    async with httpx.AsyncClient(timeout=30.0) as http:
        provider = InstallationTokenProvider(
            os.environ["GITHUB_APP_ID"],
            os.environ["GITHUB_INSTALLATION_ID"],
            os.environ["GITHUB_APP_KEY_PATH"],
            repo=args.repo,
            http=http,
        )
        try:
            res = await run_spike_pr(http, provider, repo=args.repo, base=args.base, scenario=args.scenario,
                                     wait=not args.no_wait, timeout_s=args.timeout)
        except SpikeError as e:
            print(f"refused: {e}", file=sys.stderr)
            return 2
    print(f"pr={res.number} branch={res.branch} url={res.url}")
    print(f"auto_merge_enabled={res.auto_merge_enabled} error={res.auto_merge_error or '-'}")
    print(f"final_state={res.final_state} merged={res.merged} mergeable_state={res.mergeable_state or '-'} waited_s={res.waited_s:.0f}")
    print(f"head_branch_deleted={res.branch_deleted}")
    return 0 if res.merged or args.no_wait else 1


def _app_provider(http: httpx.AsyncClient, repo: str) -> InstallationTokenProvider | None:
    for key in ("GITHUB_APP_ID", "GITHUB_INSTALLATION_ID", "GITHUB_APP_KEY_PATH"):
        if not os.environ.get(key):
            print(f"missing {key} (load .env)", file=sys.stderr)
            return None
    return InstallationTokenProvider(
        os.environ["GITHUB_APP_ID"],
        os.environ["GITHUB_INSTALLATION_ID"],
        os.environ["GITHUB_APP_KEY_PATH"],
        repo=repo,
        http=http,
    )


async def _open_test_pr(args: argparse.Namespace) -> int:
    async with httpx.AsyncClient(timeout=30.0) as http:
        provider = _app_provider(http, args.repo)
        if provider is None:
            return 2
        try:
            res = await run_open_test_pr(http, provider, repo=args.repo, base=args.base, scenario=args.scenario,
                                         branch=args.branch)
        except NegativePrError as e:
            print(f"refused: {e}", file=sys.stderr)
            return 2
    # Machine lines, "key: value", for tests/e2e/policy-negative.sh.
    print(f"scenario: {res.scenario}")
    print(f"branch: {res.branch}")
    if res.number is not None:
        print(f"pr: {res.number}")
        print(f"url: {res.url}")
        print(f"head: {res.head}")
    if res.refused_status is not None:
        print(f"refused_status: {res.refused_status}")
        print(f"refused_message: {res.refused_message}")
    if res.note:
        print(f"note: {res.note}")
    if args.scenario == "tamper-workflow":
        return 0 if res.refused_status is not None else 1
    return 0


async def _test_pr_try_merge(args: argparse.Namespace) -> int:
    async with httpx.AsyncClient(timeout=30.0) as http:
        provider = _app_provider(http, args.repo)
        if provider is None:
            return 2
        try:
            res = await run_test_pr_try_merge(http, provider, repo=args.repo, number=args.pr, rest=args.rest)
        except NegativePrError as e:
            print(f"refused: {e}", file=sys.stderr)
            return 2
    print(f"auto_merge_enabled: {str(res.auto_merge_enabled).lower()}")
    print(f"auto_merge_error: {res.auto_merge_error or '-'}")
    if res.rest_status is not None:
        print(f"rest_status: {res.rest_status}")
        print(f"rest_message: {res.rest_message or '-'}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="bridge.cli", description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("try-direct-push", help="prove the App cannot write to protected refs")
    t.add_argument("--repo", default=os.environ.get("REPO_SLUG", ""), help="OWNER/NAME (default: $REPO_SLUG)")
    t.add_argument("--branches", default=os.environ.get("RULESET_BRANCHES", ""), help="comma list (default: $RULESET_BRANCHES)")
    t.add_argument("--operator-ref", default=None,
                   help="a promote/* branch the operator pushed; the App tries to move and delete it")
    sp = sub.add_parser("spike-pr", help="open an App-authored PR on the scratch branch and enable auto-merge")
    sp.add_argument("--repo", default=os.environ.get("REPO_SLUG", ""), help="OWNER/NAME (default: $REPO_SLUG)")
    sp.add_argument("--base", required=True, help=f"must be {SPIKE_BASE}")
    sp.add_argument("--scenario", choices=["two-line", "autonomy-raise"], default="two-line")
    sp.add_argument("--timeout", type=float, default=600.0, help="seconds to wait for MERGED (default 600)")
    sp.add_argument("--no-wait", action="store_true", help="open and enable auto-merge, do not wait")
    op = sub.add_parser("open-test-pr", help="e2e only: open an App-authored policy-negative test PR on agent/test-*")
    op.add_argument("--repo", default=os.environ.get("REPO_SLUG", ""), help="OWNER/NAME (default: $REPO_SLUG)")
    op.add_argument("--base", default=os.environ.get("TRACKED_BRANCH", ""), help="default: $TRACKED_BRANCH")
    op.add_argument("--scenario", choices=SCENARIOS, required=True)
    op.add_argument("--branch", default=None, help=f"default {TEST_PR_PREFIX}<scenario>-<epoch>; must start {TEST_PR_PREFIX}")
    tm = sub.add_parser("test-pr-try-merge", help="e2e only: enable auto-merge (and with --rest, REST-merge) a test PR as the App")
    tm.add_argument("--repo", default=os.environ.get("REPO_SLUG", ""), help="OWNER/NAME (default: $REPO_SLUG)")
    tm.add_argument("--pr", type=int, required=True)
    tm.add_argument("--rest", action="store_true", help="also try a REST merge")
    args = ap.parse_args(argv)
    if args.repo.count("/") != 1:
        ap.error("--repo must be OWNER/NAME")
    if args.cmd == "spike-pr":
        return asyncio.run(_spike_pr(args))
    if args.cmd == "open-test-pr":
        if not args.base:
            ap.error("--base (or TRACKED_BRANCH) is required")
        return asyncio.run(_open_test_pr(args))
    if args.cmd == "test-pr-try-merge":
        return asyncio.run(_test_pr_try_merge(args))
    return asyncio.run(_try_direct_push(args))


if __name__ == "__main__":
    sys.exit(main())
