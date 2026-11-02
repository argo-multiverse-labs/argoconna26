"""The dry-run scorer (Task 6.1): one RCA against the incident's known answer.

Only the final RCA is scored (O14: several tool calls per investigation, some of them
failing, are normal). Two numbers come out of it:

- `root_cause_matched`: the cause SHA, the file and key, and the from/to values are right,
  and nothing was refused. This is the number the slide's "matched the expected root cause"
  means.
- `matched`: all of that, plus the fix passes the auto-fix policy, the delivery context
  cites the change reference from the timeline, and nothing tripped the PII scan.

The delivery context counts only when it names the expected `change_ref` and HolmesGPT
made a successful `GET /timeline` call. The cause SHA, the change's age and "config-version
was not bumped" are never enough: the hook's history, the incident window and the cluster
give those away too. Only the change reference is exclusive to the timeline (Δ28).
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass

from .guardrails import Refusal, normalize_path, normalize_value
from .pii import PiiHit
from .rca import RCA

_HEX_PREFIX = re.compile(r"^[0-9a-f]{7,40}$")
#: The stage label of a successful timeline read (holmes.tool_call_label). A refused call
#: carries " (refused)"; /incidents holds no change events.
TIMELINE_CALL = "GET /timeline"


@dataclass(frozen=True)
class Expected:
    """The incident's known answer, from the cause commit (Task 6.2)."""

    cause_sha: str
    file: str
    key: str
    from_value: str
    to_value: str
    #: The `change_ref:` the batch's `rearm` printed; only the timeline holds it.
    change_ref: str = ""


@dataclass(frozen=True)
class Score:
    sha_ok: bool
    key_ok: bool
    values_ok: bool
    policy_ok: bool
    delivery_context_ok: bool
    pii_clean: bool
    change_ref_cited: bool
    root_cause_matched: bool
    matched: bool


NOTHING = Score(False, False, False, False, False, False, False, False, False)


def timeline_call_made(tool_calls: Sequence[str]) -> bool:
    """True when one call is exactly a successful `GET /timeline` (query strings are not in labels)."""
    return any(call.strip() == TIMELINE_CALL for call in tool_calls)


def _sha_ok(raw: str, expected: str) -> bool:
    sha = raw.strip().lower()
    return bool(_HEX_PREFIX.match(sha)) and expected.lower().startswith(sha)


def score(
    rca: RCA | None,
    tool_calls: Sequence[str],
    expected: Expected,
    refusals: Sequence[Refusal],
    pii_hits: Sequence[PiiHit],
    policy_ok: bool,
) -> Score:
    """Score one run. `rca` is the guardrail-normalized answer; None (HolmesGPT failed or
    gave bad output) scores all false."""
    if rca is None:
        return NOTHING
    patch = rca.proposed_patch
    sha_ok = _sha_ok(rca.cause_commit_sha, expected.cause_sha)
    key_ok = normalize_path(patch.file) == expected.file and patch.key.strip() == expected.key
    values_ok = (
        normalize_value(patch.from_value) == expected.from_value
        and normalize_value(patch.to_value) == expected.to_value
    )
    ref = expected.change_ref.strip().lower()
    change_ref_cited = bool(ref) and ref in rca.delivery_context.lower()
    delivery_context_ok = change_ref_cited and timeline_call_made(tool_calls)
    pii_clean = not pii_hits
    # A refusal (low confidence included) posts nothing on stage, so it is never a match.
    root_cause_matched = sha_ok and key_ok and values_ok and not refusals
    matched = root_cause_matched and policy_ok and delivery_context_ok and pii_clean
    return Score(
        sha_ok=sha_ok,
        key_ok=key_ok,
        values_ok=values_ok,
        policy_ok=policy_ok,
        delivery_context_ok=delivery_context_ok,
        pii_clean=pii_clean,
        change_ref_cited=change_ref_cited,
        root_cause_matched=root_cause_matched,
        matched=matched,
    )
