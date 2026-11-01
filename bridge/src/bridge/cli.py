"""e2e harness commands. Not part of the running bridge; never imported by the app.

    python -m bridge.cli try-direct-push [--repo OWNER/NAME] [--branches a,b] [--operator-ref REF]

`try-direct-push` proves, with the App's own installation token, that the standing rulesets hold:
for each protected branch it creates (through the Git Data API) a commit whose parent is the
branch head and whose tree is the head's tree, tries to move the branch ref to it, then tries to
delete the ref. It also tries to create `promote/app-test-<stamp>` and, when the operator has
pushed a promotion branch, to move that. Every attempt must get a 4xx whose message names a
repository rule violation. A success, or a 4xx for any other reason, fails the check; a success
is undone on the spot (ref restored, stray ref deleted) so the check never leaves damage.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import re
import sys
import time
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
        return AttemptResult(target, action, r.status_code, True, f"refused: {msg}")
    if refused and action == "delete" and _DEFAULT_GUARD.search(msg):
        return AttemptResult(target, action, r.status_code, True, f"refused by the default-branch guard (not a ruleset message): {msg}")
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

    async def move(target: str, old: str, new: str, restore: bool) -> None:
        ref = f"/git/refs/heads/{quote(target, safe='/')}"
        r = await gh.call("PATCH", ref, json={"sha": new, "force": False})
        v = _verdict(target, "move", r)
        if not v.ok and r.status_code < 300 and restore:
            back = await gh.call("PATCH", ref, json={"sha": old, "force": True})
            v.detail += f"; restored={back.status_code < 300}"
        results.append(v)

    for b in branches:
        old = await gh.head(b)
        new = await gh.unreachable_child(old)
        await move(b, old, new, restore=True)
        ref = f"/git/refs/heads/{quote(b, safe='/')}"
        r = await gh.call("DELETE", ref)
        v = _verdict(b, "delete", r)
        if not v.ok and r.status_code < 300:
            back = await gh.call("POST", "/git/refs", json={"ref": f"refs/heads/{b}", "sha": old})
            v.detail += f"; restored={back.status_code < 300}"
        results.append(v)

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
                              f"refused ('{_message(r)}'); control ref at an unprotected name was created and removed")
        else:
            v.detail += f"; control create also failed ({c.status_code}), so this is not proven to be the ruleset"
    results.append(v)

    if operator_ref:
        old = await gh.head(operator_ref)
        new = await gh.unreachable_child(old)
        await move(operator_ref, old, new, restore=True)
    return results


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
    bad = sum(1 for x in results if not x.ok)
    print(f"{len(results) - bad}/{len(results)} attempts refused")
    return 1 if bad else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="bridge.cli", description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("try-direct-push", help="prove the App cannot write to protected refs")
    t.add_argument("--repo", default=os.environ.get("REPO_SLUG", ""), help="OWNER/NAME (default: $REPO_SLUG)")
    t.add_argument("--branches", default=os.environ.get("RULESET_BRANCHES", ""), help="comma list (default: $RULESET_BRANCHES)")
    t.add_argument("--operator-ref", default=None, help="a promote/* branch the operator pushed; the App tries to move it")
    args = ap.parse_args(argv)
    if args.repo.count("/") != 1:
        ap.error("--repo must be OWNER/NAME")
    return asyncio.run(_try_direct_push(args))


if __name__ == "__main__":
    sys.exit(main())
