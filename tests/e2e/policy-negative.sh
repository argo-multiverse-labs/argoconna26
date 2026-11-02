#!/usr/bin/env bash
# Policy negative cases (Task 5.6 Step 2), each through `python -m bridge.cli open-test-pr`, so
# every PR is App-authored (the bot) and the auto-fix step of policy-check runs. GitHub only: no
# cluster, no write to the tracked branch. Every test PR is titled "[policy negative test] ...",
# says it was opened by the operator with the agent's identity, and carries the label
# policy-negative-test, so the reconciler counts none of them (O23).
#
#   image-change       a fix-shaped change plus an image tag bump: policy-check fails with "rule 4:"
#   tamper-autofix     the same, plus policy/autofix.rego edited to `deny := set()`: still "rule 4:",
#                      so the deny came from the base branch's rules, not the PR's
#   tamper-goldenpath  a golden-path label removed, plus golden_path.rego loosened: the golden-path
#                      message for the missing label, so golden-path also ran from the base policy
#   tamper-workflow    the App's commit touching .github/workflows/policy.yml is refused with a 4xx
#                      (no workflows permission, P21) and no PR exists
#   tamper-autonomy    an App-authored PR that sets level: act: policy-check fails ("rule 1:");
#                      needs autonomy below act on the tracked branch
#
# What GitHub itself must block depends on the live rules on the tracked branch (read, never
# changed, from GET /repos/{r}/rules/branches/{branch}):
#   - with the required policy-check status live: enable auto-merge with the App token (as the
#     bridge does), then mergeStateStatus is BLOCKED and the PR is still unmerged 60 s after the
#     check concluded; for tamper-autonomy also a REST merge with the App token gets a 4xx
#   - with code-owner review live: tamper-autonomy's reviewDecision is REVIEW_REQUIRED
# Without them those assertions print DEFERRED and no merge is attempted at all (nothing would
# stop it). What always holds: the check fails with the right rule from the base-ref policy, and
# nobody merges the PR (still unmerged 60 s after the check concluded).
# Then each PR is closed and its branch deleted.
#
# Usage, from the main checkout: tests/e2e/policy-negative.sh [SCENARIO...]   (default: all five)
# Output: PASS/FAIL/DEFERRED lines, also saved under $EVIDENCE_DIR/slice-5/policy-negative-<ts>.txt.
# Exit 0 when nothing FAILed (DEFERRED is not a failure), 1 otherwise.
set -euo pipefail
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$E2E_DIR/../../scripts/common.sh"

ALL=(image-change tamper-autofix tamper-goldenpath tamper-workflow tamper-autonomy)
CHECK_WAIT_S="${CHECK_WAIT_S:-600}"
HOLD_S="${HOLD_S:-60}"
TEST_LABEL=policy-negative-test
FAILS=0
OUT=""
REQUIRED_CHECK=0
CODE_OWNER=0

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
pass() { say "PASS $1: $2"; }
failc() { say "FAIL $1: $2"; FAILS=$((FAILS + 1)); }
deferred() { say "DEFERRED $1: $2"; }

cli() { # ARGS... : the bridge's e2e CLI with the App credentials from .env
  (cd "$ROOT/bridge" && uv run --quiet python -m bridge.cli "$@")
}
machine() { sed -n "s/^$1: //p" <<<"$2" | tail -n1; }

live_rules() {
  local rules
  rules="$(gh api "repos/$REPO_SLUG/rules/branches/$TRACKED_BRANCH" --paginate --jq '.[]' | jq -s .)"
  if jq -e --arg c "$POLICY_CHECK_CONTEXT" \
      'any(.[]; .type == "required_status_checks" and any(.parameters.required_status_checks[]; .context == $c))' \
      <<<"$rules" >/dev/null; then
    REQUIRED_CHECK=1
  fi
  if jq -e 'any(.[]; .type == "pull_request" and .parameters.require_code_owner_review == true)' <<<"$rules" >/dev/null; then
    CODE_OWNER=1
  fi
  say "live rules on $TRACKED_BRANCH: required $POLICY_CHECK_CONTEXT=$( ((REQUIRED_CHECK)) && echo on || echo off), code-owner review=$( ((CODE_OWNER)) && echo on || echo off)"
}

ensure_label() {
  gh api "repos/$REPO_SLUG/labels/$TEST_LABEL" >/dev/null 2>&1 \
    || gh api -X POST "repos/$REPO_SLUG/labels" -f name="$TEST_LABEL" -f color=b60205 \
         -f description="Opened by the operator with the agent's identity to test the policy (e2e only)" >/dev/null
}

# The policy-check run on SHA from GitHub Actions, as JSON, or nothing.
check_run() {
  gh api "repos/$REPO_SLUG/commits/$1/check-runs?check_name=$POLICY_CHECK_CONTEXT&per_page=100" \
    --jq "[.check_runs[] | select(.app.id == $POLICY_CHECK_INTEGRATION_ID)] | sort_by(.started_at) | last // empty"
}
check_done() { [[ "$(check_run "$1" | jq -r '.status // ""')" == completed ]]; }

pr_merged() { [[ "$(gh pr view "$1" --repo "$REPO_SLUG" --json state --jq .state)" == MERGED ]]; }

# Unmerged for HOLD_S seconds after the check concluded at EPOCH (polled, not slept through).
hold_unmerged() { # CASE PR CONCLUDED_EPOCH
  local end=$(($3 + HOLD_S))
  while (($(date +%s) < end)); do
    if pr_merged "$2"; then failc "$1" "PR $2 was MERGED within ${HOLD_S}s of the check concluding"; return 1; fi
    sleep 5
  done
  if pr_merged "$2"; then failc "$1" "PR $2 is MERGED"; return 1; fi
  pass "$1" "PR $2 still unmerged ${HOLD_S}s after policy-check concluded"
}

close_and_delete() { # PR BRANCH
  gh pr close "$1" --repo "$REPO_SLUG" --comment "closed by tests/e2e/policy-negative.sh" >/dev/null 2>&1 || true
  gh api -X DELETE "repos/$REPO_SLUG/git/refs/heads/$2" >/dev/null 2>&1 || true
  if gh api "repos/$REPO_SLUG/git/ref/heads/$2" >/dev/null 2>&1; then
    failc cleanup "branch $2 still exists"
  fi
}

# Open the scenario's PR; sets PR, BRANCH, HEAD. Returns 1 (after a FAIL line) if it could not.
open_pr() { # SCENARIO
  local out rc=0
  out="$(cli open-test-pr --scenario "$1" 2>&1)" || rc=$?
  printf '%s\n' "$out" >>"$OUT"
  PR="$(machine pr "$out")" BRANCH="$(machine branch "$out")" HEAD="$(machine head "$out")"
  if ((rc != 0)) || [[ ! "$PR" =~ ^[0-9]+$ ]]; then
    failc "$1" "open-test-pr exited $rc: $(tail -n1 <<<"$out")"
    [[ "$BRANCH" == agent/test-* ]] && gh api -X DELETE "repos/$REPO_SLUG/git/refs/heads/$BRANCH" >/dev/null 2>&1
    return 1
  fi
  local v
  v="$(gh pr view "$PR" --repo "$REPO_SLUG" --json author,labels,title,body)"
  if jq -e --arg l "$TEST_LABEL" '(.labels | map(.name) | index($l)) != null and (.title | startswith("[policy negative test]"))
        and (.body | contains("not opened by the agent"))' <<<"$v" >/dev/null; then
    pass "$1" "PR $PR on $BRANCH by $(jq -r .author.login <<<"$v"), labelled $TEST_LABEL"
  else
    failc "$1" "PR $PR lacks the label, title or body of a test PR"
  fi
}

# Wait for policy-check on HEAD; sets CONCLUSION, CONCLUDED (epoch), LOG.
wait_check() { # CASE
  if ! wait_for "policy-check on ${HEAD:0:7} (PR $PR)" "$CHECK_WAIT_S" check_done "$HEAD"; then
    failc "$1" "policy-check did not complete within ${CHECK_WAIT_S}s"; return 1
  fi
  local run
  run="$(check_run "$HEAD")"
  CONCLUSION="$(jq -r .conclusion <<<"$run")"
  CONCLUDED="$(date -d "$(jq -r .completed_at <<<"$run")" +%s)"
  LOG="$(gh api "repos/$REPO_SLUG/actions/jobs/$(jq -r .id <<<"$run")/logs" 2>/dev/null || true)"
  printf -- '--- policy-check log (PR %s), failure lines\n%s\n---\n' "$PR" \
    "$(grep -E 'FAIL|::error|rule [0-9]:|missing required label' <<<"$LOG" | head -n 20)" >>"$OUT"
}

expect_failure_with() { # CASE REGEX WHAT
  if [[ "$CONCLUSION" != failure ]]; then
    failc "$1" "policy-check concluded '$CONCLUSION', expected failure"; return
  fi
  if grep -qE "$2" <<<"$LOG"; then
    pass "$1" "policy-check failed with $3 (base-ref policy)"
  else
    failc "$1" "policy-check failed, but its log has no $3"
  fi
}

# With the required check live: enable auto-merge as the App, then BLOCKED and unmerged.
github_blocks() { # CASE [--rest]
  local case="$1" out state
  shift
  if ((!REQUIRED_CHECK)); then
    deferred "$case" "auto-merge attempt, mergeStateStatus BLOCKED and GitHub refusing the merge need the required $POLICY_CHECK_CONTEXT status (L5b); no merge attempted"
    hold_unmerged "$case" "$PR" "$CONCLUDED" || true
    return
  fi
  out="$(cli test-pr-try-merge --pr "$PR" "$@" 2>&1)" || { failc "$case" "test-pr-try-merge failed: $(tail -n1 <<<"$out")"; return; }
  printf '%s\n' "$out" >>"$OUT"
  say "  auto-merge as the App: enabled=$(machine auto_merge_enabled "$out") error=$(machine auto_merge_error "$out")"
  if [[ " $* " == *" --rest "* ]]; then
    local st
    st="$(machine rest_status "$out")"
    if [[ "$st" =~ ^4[0-9][0-9]$ ]]; then
      pass "$case" "REST merge with the App token refused: $st $(machine rest_message "$out")"
    else
      failc "$case" "REST merge with the App token returned '$st', expected a 4xx"
    fi
  fi
  state="$(gh pr view "$PR" --repo "$REPO_SLUG" --json mergeStateStatus --jq .mergeStateStatus)"
  if [[ "$state" == BLOCKED ]]; then
    pass "$case" "mergeStateStatus BLOCKED"
  else
    failc "$case" "mergeStateStatus is $state, expected BLOCKED"
  fi
  hold_unmerged "$case" "$PR" "$CONCLUDED" || true
}

case_check_fail() { # SCENARIO REGEX WHAT
  open_pr "$1" || return 0
  if wait_check "$1"; then
    expect_failure_with "$1" "$2" "$3"
    github_blocks "$1"
  fi
  close_and_delete "$PR" "$BRANCH"
}

case_tamper_workflow() {
  local out rc=0 st
  out="$(cli open-test-pr --scenario tamper-workflow 2>&1)" || rc=$?
  printf '%s\n' "$out" >>"$OUT"
  st="$(machine refused_status "$out")"
  if ((rc == 0)) && [[ "$st" =~ ^4[0-9][0-9]$ ]] && [[ -z "$(machine pr "$out")" ]]; then
    pass tamper-workflow "the App's commit to .github/workflows/policy.yml was refused: $st $(machine refused_message "$out"); no PR opened"
  else
    failc tamper-workflow "expected a 4xx and no PR (exit $rc, status '${st:-none}'): $(tail -n2 <<<"$out" | tr '\n' ' ')"
  fi
  local b
  b="$(machine branch "$out")"
  if [[ -n "$b" ]] && gh api "repos/$REPO_SLUG/git/ref/heads/$b" >/dev/null 2>&1; then
    failc tamper-workflow "branch $b exists"
    gh api -X DELETE "repos/$REPO_SLUG/git/refs/heads/$b" >/dev/null 2>&1 || true
  fi
}

case_tamper_autonomy() {
  local lvl
  lvl="$(tracked_autonomy_level || true)"
  if [[ "$lvl" == act || -z "$lvl" ]]; then
    failc tamper-autonomy "autonomy on $TRACKED_BRANCH is '${lvl:-unreadable}': the agent can only try to raise it from below act (make demote first)"
    return 0
  fi
  open_pr tamper-autonomy || return 0
  if wait_check tamper-autonomy; then
    expect_failure_with tamper-autonomy '(^|[^0-9A-Za-z])rule 1: ' '"rule 1:"'
    if ((CODE_OWNER)); then
      local d
      d="$(gh pr view "$PR" --repo "$REPO_SLUG" --json reviewDecision --jq .reviewDecision)"
      if [[ "$d" == REVIEW_REQUIRED ]]; then
        pass tamper-autonomy "reviewDecision REVIEW_REQUIRED (code-owner review on $AUTONOMY_FILE)"
      else
        failc tamper-autonomy "reviewDecision is '$d', expected REVIEW_REQUIRED"
      fi
    else
      deferred tamper-autonomy "reviewDecision REVIEW_REQUIRED needs code-owner review on $TRACKED_BRANCH (L4/L5b)"
    fi
    github_blocks tamper-autonomy --rest
  fi
  close_and_delete "$PR" "$BRANCH"
}

main() {
  local cases=("$@") c
  ((${#cases[@]})) || cases=("${ALL[@]}")
  for c in "${cases[@]}"; do
    [[ " ${ALL[*]} " == *" $c "* ]] || die "unknown scenario '$c' (one of: ${ALL[*]})"
  done
  load_env
  ROOT="$(cd "$E2E_DIR/../.." && pwd)"
  local evdir
  evdir="$(evidence_dir)/slice-5"
  mkdir -p "$evdir"
  OUT="$evdir/policy-negative-$(date -u +%Y%m%dT%H%M%SZ).txt"
  : >"$OUT"
  say "policy-negative: $(date -u +%Y-%m-%dT%H:%M:%SZ) start ($(date +%s)), cases: ${cases[*]}"
  live_rules
  ensure_label
  for c in "${cases[@]}"; do
    say "== $c"
    case "$c" in
      image-change) case_check_fail image-change '(^|[^0-9A-Za-z])rule 4: ' '"rule 4:"' ;;
      tamper-autofix) case_check_fail tamper-autofix '(^|[^0-9A-Za-z])rule 4: ' '"rule 4:" (not the PR'"'"'s deny := set())' ;;
      tamper-goldenpath) case_check_fail tamper-goldenpath 'Deployment pricing: missing required label example\.dev/owner' \
                           'the golden-path message for the missing example.dev/owner label' ;;
      tamper-workflow) case_tamper_workflow ;;
      tamper-autonomy) case_tamper_autonomy ;;
    esac
  done
  say "policy-negative: end ($(date +%s))"
  if ((FAILS == 0)); then say "policy-negative: PASS (output $OUT)"; else say "policy-negative: FAIL ($FAILS; output $OUT)"; exit 1; fi
}

main "$@"
