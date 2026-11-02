#!/usr/bin/env bash
# Rung 3 (act) end to end on the real kind cluster and real GitHub, through the scheduled job.
#
#   redeploy bridge and sim -> pre-promotion state (autonomy propose, no open agent PR,
#   disarm --image v1.4.1, preflight 3 --pre-promotion) -> promotion PR propose -> act,
#   merge --admin (D5), record-approval -> preflight 3 --armed -> release the lock
#   -> T0 = make night (the job unit re-arms) -> the bot's fix PR -> policy-check -> merged with no
#   human action -> synced (Argo's own reconciliation; RUNG3_REFRESH=1 nudges it) -> Healthy -> overnight-verify.sh for the run window
#
# What it asserts:
#   - make night exits 0, and the unit's journal since RUN_TS has the cause and bump SHAs
#   - exactly one PR from BOT_LOGIN on agent/checkout-* created after T0; its diff is the two
#     changed lines, its body's first "Cause:" line is the journal's cause and it has the act footer
#   - it reaches MERGED within MERGED_WAIT_S (15 min), mergedBy the bot (GitHub's auto-merge or the
#     bridge's fallback), no reviews; its Timeline line cites the journal's change_ref and no other
#   - Argo syncs the merge commit and checkout is Healthy
#   - /events has the bridge's agent-action events and its change.merged for the PR since T0
#   - aiops_policy_checks_total{result="pass"} rose by one over the start value
#   - tests/e2e/overnight-verify.sh SINCE=<RUN_TS> UNTIL=<now> passes (it writes the window file)
# Then the PR is labelled demo-reset (O23) and its branch deleted. Autonomy stays at act; the
# next run (or make demote) lowers it.
#
# Timings: one "rung3:" line on stdout and a row in $EVIDENCE_DIR/slice-5/rung3-runs-v2.tsv.
# typed_to_pr_s counts from when scripts/night.sh started (T_TYPED, before its own preflight);
# trigger_to_pr_s from RUN_TS (the unit's start, the verifier's window start). By default
# Argo is not nudged after the merge (RUNG3_REFRESH=0), as on the make night path.
# Usage, from the main checkout: tests/e2e/rung3.sh
# Exit codes: 1 an assertion failed, 3 wrong context, 4 a wait timed out, 5 cluster lock held.

set -euo pipefail
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git-ops.sh
. "$E2E_DIR/../../scripts/git-ops.sh"
# shellcheck source=tests/e2e/assert.sh
. "$E2E_DIR/assert.sh"
E2E_NAME=rung3
# shellcheck source=tests/e2e/harness.sh
. "$E2E_DIR/harness.sh"

PR_WAIT_S="${PR_WAIT_S:-300}"
MERGED_WAIT_S="${MERGED_WAIT_S:-900}"
HEALTHY_WAIT_S="${HEALTHY_WAIT_S:-240}"
METRIC_WAIT_S="${METRIC_WAIT_S:-180}"
RUNG3_REFRESH="${RUNG3_REFRESH:-0}"   # 1: annotate refresh=normal on the merge (not on the make night path)

machine() { sed -n "s/^$1: //p" <<<"$2" | tail -n1; } # KEY TEXT

delete_remote_branch() { # BRANCH : best effort; a 404/422 means it is already gone
  if gh api -X DELETE "repos/$REPO_SLUG/git/refs/heads/$1" >/dev/null 2>&1; then
    log_info "rung3: deleted branch $1"
  fi
}

close_open_agent_prs() {
  local n branch
  for n in $(open_agent_prs checkout); do
    branch="$(gh pr view "$n" --repo "$REPO_SLUG" --json headRefName --jq .headRefName)"
    label_demo_reset "$n"
    gh pr close "$n" --repo "$REPO_SLUG" --comment "closed by tests/e2e/rung3.sh (demo reset)" >/dev/null
    log_warn "rung3: closed leftover agent PR $n"
    delete_remote_branch "$branch"
  done
}

promote_to() { # LEVEL : ensure, merge --admin, record-approval
  local out pr branch
  out="$(run_promo ensure "$1")"
  pr="$(machine pr "$out")"
  branch="$(machine branch "$out")"
  [[ "$pr" =~ ^[0-9]+$ && "$branch" == "promote/$1-"* ]] || fail "ensure $1 did not print pr and branch"
  PROMO_PR="$pr" PROMO_BRANCH="$branch"
  [[ "$(gh pr diff "$pr" --repo "$REPO_SLUG" --name-only)" == "$AUTONOMY_FILE" ]] \
    || fail "promotion PR $pr does not change exactly $AUTONOMY_FILE"
  run_promo merge "$pr" --admin >/dev/null
  pr_state_is "$pr" MERGED || fail "promotion PR $pr is not MERGED"
  delete_remote_branch "$branch"
  PROMO_BRANCH=""
  run_promo record-approval "$pr" >/dev/null
  wait_for "$AUTONOMY_FILE@$TRACKED_BRANCH is $1" 60 tracked_level_is "$1"
}

# The pre-promotion state: autonomy propose, no open agent PR, disarmed at the stable tag.
pre_promotion_state() {
  local lvl
  close_open_agent_prs
  op_sync
  lvl="$(yaml_get "$AUTONOMY_FILE" .level)"
  if [[ "$lvl" == act ]]; then
    run_promo demote >/dev/null
  elif [[ "$lvl" == suggest ]]; then
    # Disarm first: at propose a stray incident would open a PR.
    run_make disarm IMAGE="$CHECKOUT_STABLE_TAG" >/dev/null
    promote_to propose
  fi
  wait_for "$AUTONOMY_FILE@$TRACKED_BRANCH is propose" 60 tracked_level_is propose
  run_make disarm IMAGE="$CHECKOUT_STABLE_TAG" >/dev/null
}

release_lock() {
  eval "exec ${CLUSTER_LOCK_FD}>&-"
  unset CLUSTER_LOCK_HELD
  wait_for "the cluster lock is free" 30 _lock_free || fail "the cluster lock is still held: $(head -n1 "$(_lock_file)")"
}
_lock_free() { ! _lock_is_held "$(_lock_file)"; }

journal_since() { # EPOCH -> the unit's messages since then
  journalctl --user -u argoconna26-rearm.service --since "@$1" -o cat --no-pager 2>/dev/null || true
}

bot_events_since() { # TYPE T0 -> the bridge's events of TYPE for checkout since T0 (JSON lines)
  curl -sf --max-time 5 --get --data-urlencode app=checkout --data-urlencode "type=$1" \
    --data-urlencode "since=$(date -u -d "@$2" +%Y-%m-%dT%H:%M:%SZ)" "$(_sim_url)/events" | jq -c '.[]'
}

merged_event_for() { bot_events_since change.merged "$1" | jq -e --arg u "$2" 'select(.customData.pr_url == $u)' >/dev/null; }

on_exit() {
  local rc=$?
  trap - EXIT
  if ((rc != 0)) && [[ -n "${RUN_LOG:-}" ]] && [[ "${RUNG3_NO_CLEANUP:-0}" != "1" ]]; then
    log_warn "rung3: failed (exit $rc); closing this run's open PRs and disarming to $CHECKOUT_STABLE_TAG"
    (close_open_agent_prs) || true
    if [[ -n "${FIX_PR:-}" ]] && pr_state_is "$FIX_PR" MERGED; then
      (label_demo_reset "$FIX_PR") || log_error "rung3: could not label PR $FIX_PR demo-reset; label it by hand"
    fi
    if [[ -n "${PROMO_PR:-}" ]] && pr_state_is "$PROMO_PR" OPEN; then
      gh pr close "$PROMO_PR" --repo "$REPO_SLUG" --comment "closed by tests/e2e/rung3.sh (failed run)" >/dev/null || true
    fi
    [[ -n "${PROMO_BRANCH:-}" ]] && delete_remote_branch "$PROMO_BRANCH"
    (run_make disarm IMAGE="$CHECKOUT_STABLE_TAG" >/dev/null) \
      || log_error "rung3: the cleanup disarm failed too; run make disarm IMAGE=$CHECKOUT_STABLE_TAG"
  fi
  exit "$rc"
}

main() {
  (($# == 0)) || die "usage: tests/e2e/rung3.sh"
  load_env
  require_context
  ROOT="$(main_root)"
  [[ "$(cd "$E2E_DIR/../.." && pwd -P)" == "$(cd "$ROOT" && pwd -P)" ]] \
    || die "run rung3.sh from the main checkout ($ROOT), not a worktree"
  cluster_lock
  trap on_exit EXIT

  local evdir run_id
  evdir="$(evidence_dir)/slice-5"
  mkdir -p "$evdir"
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_LOG="$evdir/rung3-$run_id.log"
  : >"$RUN_LOG"
  log_info "rung3: run $run_id, log $RUN_LOG"

  step "fresh bridge and sim code (Task 2.4)"
  run_make redeploy-bridge redeploy-sim >/dev/null
  "$ROOT/scripts/ensure-image.sh" --assert-running bridge || fail "bridge runs a stale image"
  "$ROOT/scripts/ensure-image.sh" --assert-running cdevents-sim || fail "cdevents-sim runs a stale image"
  wait_for "bridge /status answers" 60 bridge_status >/dev/null
  bridge_status | jq -e '.dry_forge == false and .github_token_ok == true and .holmes_reachable == true' >/dev/null \
    || { bridge_status >&2; fail "the bridge is not ready for real writes (dry_forge, GitHub token, HolmesGPT)"; }

  step "pre-promotion state: propose, no open agent PR, disarm --image $CHECKOUT_STABLE_TAG"
  local t_reset0 t_reset1
  t_reset0="$(now)"
  pre_promotion_state
  t_reset1="$(now)"
  "$ROOT/scripts/preflight.sh" 3 --pre-promotion >>"$RUN_LOG" 2>&1 || fail "preflight 3 --pre-promotion failed (see $RUN_LOG)"

  step "promotion PR propose -> act, merge --admin (D5), record-approval"
  local t_promo0 t_promo1
  t_promo0="$(now)"
  promote_to act
  t_promo1="$(now)"
  local approved
  approved="$(tracked_file "$AUTONOMY_FILE" | yq -r .promotion.approved_by)"
  [[ "$approved" == admin-bypass || "$approved" == promotion-board\ member* ]] || fail "approved_by is '$approved'"
  # preflight 3 --armed checks that cluster_lock is free (the unit can't inherit it), so release
  # it first, as on stage.
  step "release the lock; preflight 3 --armed"
  release_lock
  "$ROOT/scripts/preflight.sh" 3 --armed >>"$RUN_LOG" 2>&1 || fail "preflight 3 --armed failed (see $RUN_LOG)"

  local pass_series='aiops_policy_checks_total{result="pass"}' pass_start pass_want
  pass_start="$(bridge_metric "$pass_series")"
  pass_want="$(awk -v a="$pass_start" 'BEGIN {printf "%d", a + 1}')" # /metrics prints floats ("0.0")
  log_info "rung3: policy passes at the start: $pass_start"

  step "T0 = make night"
  local out rc=0 run_ts
  # scripts/night.sh, not make night: make turns every failure into 2.
  out="$("$ROOT/scripts/night.sh" night 2>&1)" || rc=$?
  printf '%s\n' "$out" | tee -a "$RUN_LOG" >&2
  run_ts="$(sed -n 's/^RUN_TS=//p' "$ROOT/.operator/last-run")"
  local t_typed
  t_typed="$(sed -n 's/^T_TYPED=//p' "$ROOT/.operator/last-run")"
  ((rc == 0)) || fail "scripts/night.sh night exited $rc"
  [[ "$run_ts" =~ ^[0-9]+$ ]] || fail "no RUN_TS in .operator/last-run"
  local jtext cause bump t0
  jtext="$(journal_since "$run_ts")"
  printf '%s\n' "--- unit journal since $run_ts" "$jtext" "---" >>"$RUN_LOG"
  cause="$(sed -n 's/^cause: \([0-9a-f]\{40\}\)$/\1/p' <<<"$jtext" | tail -n1)"
  bump="$(sed -n 's/^bump: \([0-9a-f]\{40\}\)$/\1/p' <<<"$jtext" | tail -n1)"
  local change_ref
  change_ref="$(sed -n 's/^change_ref: \(CHG-[A-Z2-7]\{6\}\)$/\1/p' <<<"$jtext" | tail -n1)"
  [[ -n "$change_ref" ]] || fail "no change_ref in the unit's journal since $run_ts"
  [[ "$cause" =~ ^[0-9a-f]{40}$ && "$bump" =~ ^[0-9a-f]{40}$ ]] || fail "no cause/bump in the unit's journal since $run_ts"
  t0="$(date -d "$(gh api "repos/$REPO_SLUG/commits/$bump" --jq .commit.committer.date)" +%s)"
  log_info "rung3: RUN_TS $run_ts, cause ${cause:0:7}, bump ${bump:0:7}, T0 $t0"

  step "wait for the agent's fix PR"
  wait_for "a PR from $BOT_LOGIN on agent/checkout-* created after T0" "$PR_WAIT_S" have_agent_pr_since "$t0" checkout \
    || { bridge_status >&2; fail "no fix PR within ${PR_WAIT_S}s"; }
  local prs n fix_url fix_branch t_pr body
  prs="$(agent_prs_since "$t0" checkout)"
  n="$(grep -c . <<<"$prs")"
  ((n == 1)) || fail "$n fix PRs from $BOT_LOGIN after T0, expected exactly one"
  FIX_PR="$(jq -r .number <<<"$prs")"
  local fix_pr="$FIX_PR"
  fix_url="$(jq -r .url <<<"$prs")"
  fix_branch="$(jq -r .branch <<<"$prs")"
  t_pr="$(jq -r .created <<<"$prs")"
  body="$(gh pr view "$fix_pr" --repo "$REPO_SLUG" --json body --jq .body)"
  printf '%s\n' "--- fix PR $fix_url ($fix_branch)" "$body" "---" | tee -a "$RUN_LOG" >&2
  assert_fix_pr_diff "$fix_pr" 2> >(tee -a "$RUN_LOG" >&2) || fail "fix PR $fix_pr is not exactly two changed lines"
  assert_fix_pr_body "$body" "$cause" act "$change_ref" || fail "fix PR body: wrong Cause line, act footer or Timeline line (above)"

  step "wait MERGED with no human action (policy-check, then auto-merge or the bridge's fallback)"
  wait_for "fix PR $fix_pr MERGED" "$MERGED_WAIT_S" pr_state_is "$fix_pr" MERGED \
    || { gh pr checks "$fix_pr" --repo "$REPO_SLUG" >&2 || true; fail "fix PR $fix_pr not merged within ${MERGED_WAIT_S}s"; }
  # O13: nothing on the `make night` path refreshes Argo after the merge (the unit ends at rearm,
  # the bridge has no cluster write), so by default this run waits for Argo's own reconciliation,
  # as the stage would. RUNG3_REFRESH=1 nudges it (kubectl annotate refresh=normal), as an
  # operator's demo script could; the summary records which.
  if ((RUNG3_REFRESH)); then
    k annotate application checkout -n "$NS_ARGOCD" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  fi
  local v merged_by auto merge_sha t_merge reviews slug="${BOT_LOGIN%\[bot\]}"
  v="$(gh pr view "$fix_pr" --repo "$REPO_SLUG" --json mergedBy,autoMergeRequest,mergeCommit,mergedAt,reviews)"
  merged_by="$(jq -r '.mergedBy.login // ""' <<<"$v")"
  auto="$(jq -r 'if .autoMergeRequest then "yes" else "no" end' <<<"$v")"
  merge_sha="$(jq -r '.mergeCommit.oid' <<<"$v")"
  t_merge="$(date -d "$(jq -r .mergedAt <<<"$v")" +%s)"
  reviews="$(jq '.reviews | length' <<<"$v")"
  log_info "rung3: merged by ${merged_by:-?} (autoMergeRequest: $auto), merge ${merge_sha:0:7}"
  # autoMergeRequest stays on the PR after any merge, so only mergedBy counts.
  [[ "$merged_by" == "$BOT_LOGIN" || "$merged_by" == "$slug" || "$merged_by" == "app/$slug" ]] \
    || fail "fix PR $fix_pr merged by '$merged_by', not the bot"
  ((reviews == 0)) || fail "fix PR $fix_pr has $reviews review(s)"

  local deadline=$(($(now) + 120)) t_synced
  until app_synced_at checkout "$merge_sha"; do
    (($(now) < deadline)) || fail "Argo did not sync ${merge_sha:0:7} within 120s of the merge"
    sleep 1
  done
  t_synced="$(now)"
  delete_remote_branch "$fix_branch"

  step "wait Healthy"
  wait_for "checkout Application Healthy" "$HEALTHY_WAIT_S" app_health_is checkout Healthy
  local t_healthy
  t_healthy="$(now)"
  n="$(agent_prs_since "$t0" checkout | grep -c . || true)"
  ((n == 1)) || fail "$n fix PRs from $BOT_LOGIN after T0 by Healthy, expected exactly one"

  step "timeline: the agent's actions and its change.merged"
  bot_events_since agent-action "$t0" | tee -a "$RUN_LOG" | jq -e 'select(.customData.level == "act")' >/dev/null \
    || fail "no agent-action event at level act on /events since T0"
  wait_for "the bridge's change.merged for $fix_url on /events" 120 merged_event_for "$t0" "$fix_url" \
    || fail "no change.merged event for $fix_url"
  wait_for "the incident for ${bump:0:7} resolved on /incidents" 60 incident_resolved_for "$bump" \
    || fail "the incident is not resolved on /incidents"

  step "policy pass counted (Task 5.4 reconciler)"
  wait_for "the bridge's $pass_series = $pass_want" "$METRIC_WAIT_S" \
    bridge_metric_is "$pass_series" "$pass_want" \
    || fail "the bridge's $pass_series is $(bridge_metric "$pass_series"), expected $pass_want"
  # Prometheus scrapes the bridge every 30 s at most: wait until it has the new value, so the
  # verifier's query at UNTIL sees it.
  wait_for "Prometheus has $pass_series = $pass_want" 90 grafana_value_is \
    "sum($pass_series) or vector(0)" "$pass_want" || fail "Prometheus never saw the new pass count"

  step "overnight-verify.sh for the run window"
  local until_ts
  until_ts="$(now)"
  "$E2E_DIR/overnight-verify.sh" "SINCE=$run_ts" "UNTIL=$until_ts" 2>&1 | tee -a "$RUN_LOG" >&2
  ((PIPESTATUS[0] == 0)) || fail "overnight-verify.sh failed for SINCE=$run_ts UNTIL=$until_ts"

  step "O23: label the fix PR demo-reset"
  label_demo_reset "$fix_pr" || fail "could not label fix PR $fix_pr demo-reset"

  local trig_pr=$((t_pr - run_ts)) t0_pr=$((t_pr - t0)) pr_merged=$((t_merge - t_pr)) typed_pr=$((t_pr - t_typed))
  local merge_synced=$((t_synced - t_merge)) merged_healthy=$((t_healthy - t_merge)) summary
  summary="rung3: run=$run_id run_ts=$run_ts until=$until_ts cause=${cause:0:7} promo_pr=$PROMO_PR fix_pr=$fix_pr reset_s=$((t_reset1 - t_reset0)) promotion_s=$((t_promo1 - t_promo0)) typed_to_pr_s=$typed_pr trigger_to_pr_s=$trig_pr t0_to_pr_s=$t0_pr pr_to_merged_s=$pr_merged merged_to_synced_s=$merge_synced merged_to_healthy_s=$merged_healthy merged_by=${merged_by:-auto} auto_merge=$auto argo_refresh=$RUNG3_REFRESH change_ref=$change_ref"
  printf '%s\n' "$summary" | tee -a "$RUN_LOG"
  # v2 adds typed_to_pr_s (from T_TYPED, before night.sh's own preflight) and argo_refresh.
  local tsv="$evdir/rung3-runs-v2.tsv"
  [[ -s "$tsv" ]] \
    || printf 'run\trun_ts\tuntil\tcause\tpromo_pr\tfix_pr\treset_s\tpromotion_s\ttyped_to_pr_s\ttrigger_to_pr_s\tt0_to_pr_s\tpr_to_merged_s\tmerged_to_synced_s\tmerged_to_healthy_s\tmerged_by\tauto_merge\targo_refresh\tfix_pr_url\n' >"$tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run_id" "$run_ts" "$until_ts" "$cause" "$PROMO_PR" \
    "$fix_pr" "$((t_reset1 - t_reset0))" "$((t_promo1 - t_promo0))" "$typed_pr" "$trig_pr" "$t0_pr" "$pr_merged" "$merge_synced" \
    "$merged_healthy" "$merged_by" "$auto" "$RUNG3_REFRESH" "$fix_url" >>"$tsv"
  log_info "rung3: PASS"
}

main "$@"
