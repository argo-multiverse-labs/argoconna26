#!/usr/bin/env python3
"""Extract Git facts about a fix PR for the rung-3 auto-fix policy.

The policy (policy/autofix.rego) only ever sees the JSON this prints, so it
checks Git facts and nothing else. That keeps it runnable on a GitHub-hosted
runner and outside the agent.

    python3 policy/facts/facts.py --repo . --base <base_sha> --head <head_sha> \
        --body-file <path> --author-login <login> --author-type <type> \
        --tracked-ref <ref> > facts.json

The PR diff is taken from merge-base(base, head) to head, the same set of
changes GitHub shows on the PR. History questions (was the new value seen
before, is the cited commit on the branch) are asked of --tracked-ref only,
so commits that exist only on the PR branch never count.

Anything the script can't read or parse is an error (exit 2, nothing on
stdout), so the policy check fails closed instead of judging partial facts.

Standard library plus PyYAML (safe_load only).
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import subprocess
import sys
from pathlib import PurePosixPath
from typing import Any

import yaml

# The fix-PR body template (bridge) is tested against exactly this regex.
CAUSE_RE = re.compile(r"^Cause: ([0-9a-f]{40})\b", re.MULTILINE)

DEFAULT_ANNOTATION = "example.dev/config-version"

CONFIG_PATH_RE = re.compile(r"^apps/[^/]+/config/.+")
YAML_SUFFIXES = {".yaml", ".yml", ".json"}
WORKLOAD_KINDS = {"Rollout", "Deployment", "StatefulSet", "DaemonSet"}
RBAC_KINDS = {"Role", "ClusterRole", "RoleBinding", "ClusterRoleBinding"}
CRD_KINDS = {"CustomResourceDefinition"}
APPLICATION_KINDS = {"Application", "ApplicationSet", "AppProject"}
IMAGE_KEYS = {"image", "images"}
APPLICATION_DIRS = ("gitops/",)

MAX_FILE_BYTES = 1024 * 1024
MAX_BODY_BYTES = 256 * 1024


class FactsError(Exception):
    """The facts can't be established; the caller must fail closed."""


# --- git ----------------------------------------------------------------------


def git(repo: str, *args: str) -> bytes:
    proc = subprocess.run(
        ["git", "-C", repo, *args],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", "replace").strip()
        raise FactsError(f"git {args[0]} failed: {err}")
    return proc.stdout


def git_ok(repo: str, *args: str) -> bool:
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True, check=False)
    return proc.returncode == 0


def resolve_commit(repo: str, rev: str, what: str) -> str:
    if not rev or rev.startswith("-"):
        raise FactsError(f"{what}: invalid revision")
    proc = subprocess.run(
        ["git", "-C", repo, "rev-parse", "--verify", "--quiet", "--end-of-options", f"{rev}^{{commit}}"],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise FactsError(f"{what}: unknown revision")
    return proc.stdout.decode().strip()


def commit_exists(repo: str, sha: str) -> bool:
    return git_ok(repo, "cat-file", "-e", f"{sha}^{{commit}}")


def read_blob(repo: str, commit: str, path: str) -> str | None:
    """The file's raw bytes at a commit (no filters), or None if absent."""
    spec = f"{commit}:{path}"
    if not git_ok(repo, "cat-file", "-e", spec):
        return None
    size = int(git(repo, "cat-file", "-s", spec).decode().strip())
    if size > MAX_FILE_BYTES:
        raise FactsError(f"{path}: file too large to check")
    return git(repo, "cat-file", "blob", spec).decode("utf-8", "replace")


def changed_files(repo: str, old: str, new: str) -> list[str]:
    out = git(repo, "diff", "--name-only", "--no-renames", "-z", old, new, "--")
    return sorted(p for p in out.decode("utf-8", "replace").split("\0") if p)


def first_parent(repo: str, sha: str) -> str | None:
    out = git(repo, "rev-list", "--parents", "-n", "1", sha).decode().split()
    return out[1] if len(out) > 1 else None


# --- YAML helpers -------------------------------------------------------------


def is_yaml_path(path: str) -> bool:
    return PurePosixPath(path).suffix in YAML_SUFFIXES


def parse_docs(text: str | None, path: str) -> list[Any]:
    if text is None:
        return []
    try:
        return [d for d in yaml.safe_load_all(text) if d is not None]
    except yaml.YAMLError as exc:
        raise FactsError(f"{path}: cannot parse YAML") from exc


def norm(value: Any) -> str | None:
    """Config values as strings, so 200 and "200" compare equal."""
    if value is None:
        return None
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (str, int, float)):
        return str(value)
    return json.dumps(value, sort_keys=True, default=str)


def kinds(docs: list[Any]) -> set[str]:
    return {d.get("kind") for d in docs if isinstance(d, dict) and isinstance(d.get("kind"), str)}


def collect_images(node: Any, path: str = "") -> list[str]:
    """Every value under an `image` or `images` key, anywhere in the doc."""
    found: list[str] = []
    if isinstance(node, dict):
        for key, value in node.items():
            sub = f"{path}/{key}"
            if key in IMAGE_KEYS:
                found.append(f"{sub}={json.dumps(value, sort_keys=True, default=str)}")
            else:
                found.extend(collect_images(value, sub))
    elif isinstance(node, list):
        for i, value in enumerate(node):
            found.extend(collect_images(value, f"{path}/{i}"))
    return found


def is_dockerfile(path: str) -> bool:
    name = PurePosixPath(path).name
    return name.startswith(("Dockerfile", "Containerfile")) or name.endswith((".Dockerfile", ".Containerfile"))


# --- config changes -----------------------------------------------------------


def configmap_data(doc: Any) -> dict[str, Any] | None:
    if isinstance(doc, dict) and doc.get("kind") == "ConfigMap":
        data = doc.get("data") or {}
        return data if isinstance(data, dict) else None
    return None


def config_changes_for(path: str, old_text: str | None, new_text: str | None) -> list[dict]:
    """Per-key changes in a config file.

    A ConfigMap `data` key is reported by its name. Any other change (a
    non-YAML file, a different document count, metadata, a new kind) is
    reported with a key starting with "/", which can never be a ConfigMap
    data key, so the policy can tell the two apart.
    """
    whole = [{"file": path, "key": "/", "from": None, "to": None}]
    if not is_yaml_path(path):
        return whole
    old_docs = parse_docs(old_text, path)
    new_docs = parse_docs(new_text, path)
    if len(old_docs) != len(new_docs):
        return whole
    changes: list[dict] = []
    for old, new in zip(old_docs, new_docs):
        old_data, new_data = configmap_data(old), configmap_data(new)
        if old_data is None or new_data is None:
            if old != new:
                changes.extend(whole)
            continue
        for key in sorted(set(old_data) | set(new_data), key=str):
            before, after = norm(old_data.get(key)), norm(new_data.get(key))
            if before != after:
                changes.append({"file": path, "key": str(key), "from": before, "to": after})
        old_rest = {k: v for k, v in old.items() if k != "data"}
        new_rest = {k: v for k, v in new.items() if k != "data"}
        for key in sorted(set(old_rest) | set(new_rest), key=str):
            if old_rest.get(key) != new_rest.get(key):
                changes.append({"file": path, "key": f"/{key}", "from": None, "to": None})
    return changes


def key_values(text: str | None, path: str, key: str) -> set[str | None]:
    """The values `key` has in the ConfigMaps of one version of a file."""
    values: set[str | None] = set()
    for doc in parse_docs(text, path):
        data = configmap_data(doc)
        if data is not None and key in data:
            values.add(norm(data[key]))
    return values


def value_seen_before(repo: str, tracked: str, path: str, key: str, value: str | None) -> bool:
    if value is None or key.startswith("/"):
        return False
    shas = git(repo, "rev-list", tracked, "--", path).decode().split()
    for sha in shas:
        try:
            if value in key_values(read_blob(repo, sha, path), path, key):
                return True
        except FactsError:
            continue  # an old unparseable version never counts as a match
    return False


def commit_changed_key(repo: str, sha: str, path: str, key: str) -> bool:
    if key.startswith("/"):
        return False
    parent = first_parent(repo, sha)
    after = key_values(read_blob(repo, sha, path), path, key)
    before = key_values(read_blob(repo, parent, path), path, key) if parent else set()
    return after != before


# --- workload (pod template) changes ------------------------------------------


def pod_template_annotations(doc: Any) -> dict | None:
    try:
        ann = doc["spec"]["template"]["metadata"]["annotations"]
    except (KeyError, TypeError):
        return None
    return ann if isinstance(ann, dict) else None


def strip_annotation(doc: Any, annotation: str) -> tuple[Any, str | None]:
    """A deep copy of doc without the pod-template annotation, plus its value."""
    if not isinstance(doc, dict) or doc.get("kind") not in WORKLOAD_KINDS:
        return doc, None
    clone = copy.deepcopy(doc)
    ann = pod_template_annotations(clone)
    if ann is None or annotation not in ann:
        return clone, None
    value = norm(ann.pop(annotation))
    if not ann:
        del clone["spec"]["template"]["metadata"]["annotations"]
    return clone, value


def rollout_changes(files: dict[str, tuple[Any, Any]], annotation: str) -> dict:
    workload_files = sorted(
        path for path, (old, new) in files.items() if (kinds(old) | kinds(new)) & WORKLOAD_KINDS
    )
    if not workload_files:
        return {"file": None, "config_version": None, "other_changes": False}
    path = workload_files[0]
    other = len(workload_files) > 1
    old_docs, new_docs = files[path]
    config_version = None
    if len(old_docs) != len(new_docs):
        other = True
    else:
        for old, new in zip(old_docs, new_docs):
            old_rest, before = strip_annotation(old, annotation)
            new_rest, after = strip_annotation(new, annotation)
            if old_rest != new_rest:
                other = True
            if before != after:
                if config_version is not None:
                    other = True  # more than one annotation change
                config_version = {"from": before, "to": after}
    return {"file": path, "config_version": config_version, "other_changes": other}


# --- main ---------------------------------------------------------------------


def collect(args: argparse.Namespace) -> dict:
    repo = args.repo
    base = resolve_commit(repo, args.base, "--base")
    head = resolve_commit(repo, args.head, "--head")
    tracked = resolve_commit(repo, args.tracked_ref, "--tracked-ref")
    merge_base = git(repo, "merge-base", base, head).decode().strip()
    if not merge_base:
        raise FactsError("no merge base between --base and --head")

    paths = changed_files(repo, merge_base, head)
    texts = {p: (read_blob(repo, merge_base, p), read_blob(repo, head, p)) for p in paths}
    parsed = {p: (parse_docs(o, p), parse_docs(n, p)) for p, (o, n) in texts.items() if is_yaml_path(p)}

    config = [c for p in paths if CONFIG_PATH_RE.match(p) for c in config_changes_for(p, *texts[p])]

    forbidden = {"image": False, "rbac": False, "crd": False, "application": False}
    for p in paths:
        if is_dockerfile(p):
            forbidden["image"] = True
        if p.startswith(APPLICATION_DIRS):
            forbidden["application"] = True
        if p in parsed:
            old, new = parsed[p]
            found = kinds(old) | kinds(new)
            forbidden["rbac"] |= bool(found & RBAC_KINDS)
            forbidden["crd"] |= bool(found & CRD_KINDS)
            forbidden["application"] |= bool(found & APPLICATION_KINDS)
            old_images = sorted(i for d in old for i in collect_images(d))
            new_images = sorted(i for d in new for i in collect_images(d))
            forbidden["image"] |= old_images != new_images

    seen = bool(config) and all(
        value_seen_before(repo, tracked, c["file"], c["key"], c["to"]) for c in config
    )

    body = read_body(args.body_file)
    match = CAUSE_RE.search(body)
    cited = match.group(1) if match else None
    cited_exists = cited is not None and commit_exists(repo, cited)
    on_branch = cited_exists and git_ok(repo, "merge-base", "--is-ancestor", cited, tracked)
    changed_key = (
        cited_exists
        and bool(config)
        and all(commit_changed_key(repo, cited, c["file"], c["key"]) for c in config)
    )

    return {
        "changed_files": paths,
        "config_changes": config,
        "rollout_changes": rollout_changes(parsed, args.annotation),
        "forbidden_changes": forbidden,
        "to_value_seen_before": seen,
        "cited_sha": cited,
        "cited_sha_on_branch": bool(on_branch),
        "cited_sha_changed_key": bool(changed_key),
        "author": {"login": args.author_login, "type": args.author_type},
    }


def read_body(path: str) -> str:
    try:
        with open(path, "rb") as fh:
            raw = fh.read(MAX_BODY_BYTES + 1)
    except OSError as exc:
        raise FactsError("--body-file: cannot read") from exc
    if len(raw) > MAX_BODY_BYTES:
        raise FactsError("--body-file: too large")
    return raw.decode("utf-8", "replace")


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--repo", required=True)
    p.add_argument("--base", required=True)
    p.add_argument("--head", required=True)
    p.add_argument("--body-file", required=True)
    p.add_argument("--author-login", required=True)
    p.add_argument("--author-type", required=True)
    p.add_argument("--tracked-ref", required=True)
    p.add_argument("--annotation", default=DEFAULT_ANNOTATION, help="pod-template config-version annotation key")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        facts = collect(args)
    except FactsError as exc:
        print(f"facts: {exc}", file=sys.stderr)
        return 2
    json.dump(facts, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
