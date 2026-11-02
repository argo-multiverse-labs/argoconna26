"""Task 6.1: the dry-run scorer. Only the final RCA is scored (O14); tool calls are labels."""

from __future__ import annotations

from bridge.guardrails import Refusal
from bridge.pii import PiiHit
from bridge.rca import RCA
from bridge.score import Expected, Score, score, timeline_call_made

CAUSE = "c0ffee" + "1" * 34
CONFIG = "apps/checkout/config/checkout-config.yaml"
KEY = "UPSTREAM_TIMEOUT_MS"
REF = "CHG-K7Q2ZB"
TIMELINE_CALLS = ["kubectl get rollout", "GET /timeline", "prometheus range query"]

EXPECTED = Expected(cause_sha=CAUSE, file=CONFIG, key=KEY, from_value="200", to_value="2000", change_ref=REF)


def rca(**overrides: object) -> RCA:
    data: dict = {
        "root_cause": "PR-242 cut UPSTREAM_TIMEOUT_MS to 200 without bumping config-version.",
        "cause_commit_sha": CAUSE,
        "evidence": ["Prometheus: pods started after the change report 200"],
        "delivery_context": f"{REF} merged 3 minutes before the abort as a config-only change ({CAUSE[:7]}).",
        "confidence": 0.9,
        "proposed_patch": {"file": CONFIG, "key": KEY, "from": "200", "to": "2000"},
    }
    data.update(overrides)
    return RCA.model_validate(data)


def run(r: RCA | None = None, *, tool_calls=TIMELINE_CALLS, refusals=(), pii_hits=(), policy_ok=True,
        expected=EXPECTED) -> Score:
    return score(r if r is not None else rca(), list(tool_calls), expected, list(refusals), list(pii_hits), policy_ok)


def test_perfect_rca_matches():
    s = run()
    assert s.sha_ok and s.key_ok and s.values_ok and s.policy_ok
    assert s.delivery_context_ok and s.change_ref_cited and s.pii_clean
    assert s.root_cause_matched and s.matched


def test_wrong_sha_not_matched():
    s = run(rca(cause_commit_sha="d" * 40))
    assert not s.sha_ok
    assert not s.root_cause_matched and not s.matched


def test_short_sha_of_expected_counts():
    # The guardrails resolve a short SHA before scoring; a 7+ character prefix of the
    # expected SHA (any case, any surrounding space) still counts on its own.
    assert run(rca(cause_commit_sha=CAUSE[:7])).sha_ok
    assert run(rca(cause_commit_sha=f"  {CAUSE[:12].upper()} ")).sha_ok
    assert not run(rca(cause_commit_sha=CAUSE[:6])).sha_ok
    assert not run(rca(cause_commit_sha=CAUSE[:7] + "zz")).sha_ok


def test_missing_delivery_context_not_matched():
    s = run(rca(delivery_context=""))
    assert not s.change_ref_cited and not s.delivery_context_ok
    assert s.root_cause_matched  # the root cause itself is still right
    assert not s.matched


def test_delivery_context_without_timeline_fact_not_ok():
    s = run(rca(delivery_context="The change was deployed recently and broke the canary."))
    assert not s.change_ref_cited and not s.delivery_context_ok and not s.matched


def test_delivery_context_sha_only_not_ok():
    # Everything the hook's history, the incident window and the cluster also give away,
    # but not the change reference, which only the timeline holds.
    text = f"Commit {CAUSE} landed 4 minutes before the abort and did not bump config-version."
    s = run(rca(delivery_context=text))
    assert not s.change_ref_cited and not s.delivery_context_ok and not s.matched


def test_change_ref_cited_case_insensitive():
    s = run(rca(delivery_context=f"change {REF.lower()} merged 3 minutes before the abort"))
    assert s.change_ref_cited and s.delivery_context_ok and s.matched


def test_delivery_context_without_timeline_tool_call_not_ok():
    for calls in ([], ["kubectl get rollout"], ["GET /timeline (refused)"], ["GET /incidents"],
                  ["GET /events (refused)"]):
        s = run(tool_calls=calls)
        assert s.change_ref_cited, calls
        assert not s.delivery_context_ok, calls
        assert not s.matched, calls


def test_timeline_call_labels():
    assert timeline_call_made(["GET /timeline"])
    assert timeline_call_made(["prometheus range query", "GET /timeline", "GET /timeline (refused)"])
    assert not timeline_call_made(["GET /timeline (refused)"])
    assert not timeline_call_made(["GET /timeline/../events"])
    assert not timeline_call_made(["POST /timeline"])


def test_root_cause_matched_independent_of_policy():
    s = run(policy_ok=False)
    assert s.root_cause_matched
    assert not s.policy_ok and not s.matched


def test_none_rca_scores_false():
    s = score(None, TIMELINE_CALLS, EXPECTED, [], [], True)
    assert s == Score(
        sha_ok=False, key_ok=False, values_ok=False, policy_ok=False, delivery_context_ok=False,
        pii_clean=False, change_ref_cited=False, root_cause_matched=False, matched=False,
    )


def test_pii_hit_not_matched():
    s = run(pii_hits=[PiiHit("email", (0, 5))])
    assert not s.pii_clean
    assert s.root_cause_matched and not s.matched


def test_policy_fail_not_matched():
    s = run(policy_ok=False)
    assert not s.matched


def test_refusal_not_matched():
    # A low-confidence answer is a refusal: on stage nothing would be posted.
    s = run(rca(confidence=0.5), refusals=[Refusal("low_confidence", "confidence 0.50 < 0.70")])
    assert s.sha_ok and s.key_ok and s.values_ok
    assert not s.root_cause_matched and not s.matched


def test_wrong_key_or_file_or_values_not_matched():
    patch = {"file": CONFIG, "key": KEY, "from": "200", "to": "2000"}
    assert not run(rca(proposed_patch={**patch, "key": "OTHER"})).key_ok
    assert not run(rca(proposed_patch={**patch, "file": "apps/pricing/config/pricing-config.yaml"})).key_ok
    assert not run(rca(proposed_patch={**patch, "to": "5000"})).values_ok
    assert not run(rca(proposed_patch={**patch, "from": "2000", "to": "200"})).values_ok


def test_value_and_path_shapes_normalized():
    s = run(rca(proposed_patch={"file": f"./{CONFIG}", "key": f" {KEY} ", "from": '"200"', "to": "'2000'"}))
    assert s.key_ok and s.values_ok and s.root_cause_matched
