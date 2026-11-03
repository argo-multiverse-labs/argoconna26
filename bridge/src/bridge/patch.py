"""The deterministic fix builder: one config line, plus the config-version annotation +1.

The model only names the config change (`proposed_patch`). The bridge writes it as a
line-level edit, so comments, key order, quoting and line endings survive (no YAML is
ever re-dumped). Each edit is then checked by re-parsing: the new file must parse to
the old one with exactly the intended value changed, or the build fails closed.
"""

from __future__ import annotations

import copy
import json
import re
from dataclasses import dataclass
from typing import Any

import yaml

from .guardrails import normalize_path, normalize_value
from .rca import RCA

_DIGITS = re.compile(r"^[0-9]+$")


class PatchError(ValueError):
    """The fix can't be built as a safe two-line edit."""


@dataclass(frozen=True)
class FixChange:
    files: dict[str, str]
    config_version_from: str
    config_version_to: str
    diff_summary: list[str]


@dataclass(frozen=True)
class _Line:
    index: int
    head: str  # indent, key and separator, kept verbatim
    token: str  # the value as written (quotes included)
    tail: str  # trailing comment and spaces, kept verbatim
    end: str  # the line ending, kept verbatim

    @property
    def style(self) -> str:
        return self.token[0] if self.token[:1] in ("'", '"') else ""


def _key_patterns(key: str) -> tuple[re.Pattern[str], re.Pattern[str]]:
    k = re.escape(key)
    loose = re.compile(rf"""^[ \t]*(?:"{k}"|'{k}'|{k})[ \t]*:""")
    strict = re.compile(
        rf"""^(?P<head>[ \t]*(?:"{k}"|'{k}'|{k})[ \t]*:[ \t]+)"""
        # A bare value may hold `#` only right after a non-space (YAML starts a comment at ` #`).
        r"""(?P<token>"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s#'"](?:[^#]|(?<=\S)\#)*?)"""
        r"""(?P<tail>(?:[ \t]+#.*)?[ \t]*)$"""
    )
    return loose, strict


def _find_line(lines: list[str], key: str, what: str) -> _Line:
    """The single line that sets `key`; anything else raises."""
    loose, strict = _key_patterns(key)
    hits = [i for i, line in enumerate(lines) if loose.match(line.rstrip("\r\n"))]
    if not hits:
        raise PatchError(f"{key} not found in {what}" if what != "rollout" else f"{key} is missing in the rollout")
    if len(hits) > 1:
        raise PatchError(f"{key} appears more than once in {what}")
    i = hits[0]
    body = lines[i].rstrip("\r\n")
    m = strict.match(body)
    if not m:
        raise PatchError(f"{key} in {what} is not a single-line scalar")
    return _Line(i, m["head"], m["token"], m["tail"], lines[i][len(body) :])


def _scalar(token: str) -> Any:
    try:
        return yaml.safe_load(token)
    except yaml.YAMLError as exc:
        raise PatchError(f"value {token!r} does not parse") from exc


def _render(value: str, style: str) -> str:
    """`value` written in the original quoting style, or double-quoted when bare won't do."""
    if style == "'":
        return "'" + value.replace("'", "''") + "'"
    if style == "" and value and not value.endswith(" ") and "#" not in value:
        try:
            if yaml.safe_load(f"k: {value}") == {"k": value}:
                return value
        except yaml.YAMLError:
            pass
    return json.dumps(value, ensure_ascii=False)


def _replace(lines: list[str], line: _Line, value: str) -> str:
    out = list(lines)
    out[line.index] = f"{line.head}{_render(value, line.style)}{line.tail}{line.end}"
    return "".join(out)


def _load_all(text: str, what: str) -> list[Any]:
    try:
        return list(yaml.safe_load_all(text))
    except yaml.YAMLError as exc:
        raise PatchError(f"{what} is not valid YAML") from exc


def _configmap_data(docs: list[Any], key: str) -> list[dict[str, Any]]:
    return [
        d["data"]
        for d in docs
        if isinstance(d, dict)
        and d.get("kind") == "ConfigMap"
        and isinstance(d.get("data"), dict)
        and key in d["data"]
    ]


def _template_annotations(docs: list[Any], annotation: str) -> list[dict[str, Any]]:
    found = []
    for d in docs:
        try:
            ann = d["spec"]["template"]["metadata"]["annotations"]
        except (KeyError, TypeError):
            continue
        if isinstance(ann, dict) and annotation in ann:
            found.append(ann)
    return found


def _check_one_line_value(value: str) -> None:
    if not value or not value.isprintable():
        raise PatchError("the new value must be a non-empty, printable, one line string")


def _patch_config(text: str, key: str, from_value: str, to_value: str) -> str:
    lines = text.splitlines(keepends=True)
    line = _find_line(lines, key, "the config")
    current = _scalar(line.token)
    if normalize_value(current) != from_value:
        raise PatchError(f"{key} is {normalize_value(current)}, not {from_value}")
    if normalize_value(current) == to_value:
        raise PatchError(f"{key} is already {to_value}")
    new_text = _replace(lines, line, to_value)

    before, after = _load_all(text, "the config"), _load_all(new_text, "the patched config")
    targets = _configmap_data(before, key)
    if len(targets) != 1:
        raise PatchError(f"{key} not found in exactly one ConfigMap's data")
    expected = copy.deepcopy(before)
    _configmap_data(expected, key)[0][key] = to_value
    if after != expected:
        raise PatchError(f"the edit of {key} did not land on the ConfigMap's data alone")
    return new_text


def _bump_annotation(text: str, annotation: str) -> tuple[str, str, str]:
    lines = text.splitlines(keepends=True)
    line = _find_line(lines, annotation, "rollout")
    current = _scalar(line.token)
    if isinstance(current, bool) or not isinstance(current, (str, int)) or not _DIGITS.match(str(current)):
        raise PatchError(f"{annotation} is {line.token!r}, not an integer")
    cv_from, cv_to = str(current), str(int(str(current)) + 1)
    new_text = _replace(lines, line, cv_to)

    before, after = _load_all(text, "the rollout"), _load_all(new_text, "the patched rollout")
    if len(_template_annotations(before, annotation)) != 1:
        raise PatchError(f"{annotation} is missing in the pod template")
    expected = copy.deepcopy(before)
    _template_annotations(expected, annotation)[0][annotation] = _scalar(_render(cv_to, line.style))
    if after != expected or str(_template_annotations(after, annotation)[0][annotation]) != cv_to:
        raise PatchError(f"the edit of {annotation} did not land on the pod template alone")
    return new_text, cv_from, cv_to


def build_fix(rca: RCA, config_text: str, rollout_text: str, annotation: str, *, rollout_path: str) -> FixChange:
    """Build the two-file fix for `rca.proposed_patch`.

    `annotation` is the pod-template annotation that rolls the pods
    (`example.dev/config-version`); `rollout_path` is the repo path of the file
    `rollout_text` came from. Raises `PatchError` when the key is missing or appears
    more than once, the file's value isn't `from`, the annotation is missing or not an
    integer, or the re-parsed output differs from the input by more than the two values.
    """
    patch = rca.proposed_patch
    config_path = normalize_path(patch.file)
    rollout_path = normalize_path(rollout_path)
    key = patch.key.strip()
    from_value = normalize_value(patch.from_value)
    to_value = normalize_value(patch.to_value)
    if not key or not config_path:
        raise PatchError("the patch names no file or key")
    if config_path == rollout_path:
        raise PatchError("the config file and the rollout file are the same file")
    _check_one_line_value(to_value)

    new_config = _patch_config(config_text, key, from_value, to_value)
    new_rollout, cv_from, cv_to = _bump_annotation(rollout_text, annotation)
    return FixChange(
        files={config_path: new_config, rollout_path: new_rollout},
        config_version_from=cv_from,
        config_version_to=cv_to,
        diff_summary=[
            f"{config_path}: {key} {from_value} → {to_value}",
            f"{rollout_path}: {annotation} {cv_from} → {cv_to}",
        ],
    )
