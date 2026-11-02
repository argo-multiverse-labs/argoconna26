#!/usr/bin/env bash
# Rung 2 (propose) end to end on the real kind cluster and real GitHub, with the real model.
#
#   redeploy bridge and sim -> autonomy back to suggest (forward commits) -> disarm --image v1.4.1
#   -> promotion PR (ensure propose) -> merge --admin (D5) -> record-approval -> level is propose
#   -> rearm (T0 = the bump) -> Degraded -> the agent's fix PR -> merge -> refresh -> synced
#   -> fresh canary -> Healthy -> change.created and a resolved incident on the timeline
#
# What it asserts:
#   - the promotion record says admin-bypass (or a promotion-board review link), never a login
#     and never the team
#   - exactly one fix PR from BOT_LOGIN on agent/checkout-* created after T0 (counted when it
#     opens and again once Healthy), whose diff is CONFIG_FILE and ROLLOUT_FILE with one changed
#     line each, whose body's first "Cause:" line is the cause rearm printed, with the propose
#     footer and a root-cause section within the projector caps; no open agent PR at the end
#   - merge -> Argo synced at the merge commit <= MERGE_SYNC_MAX_S (30 s), a new pod hash, Healthy
#   - the timeline has the bridge's change.created for checkout and the incident is resolved
#   - aiops_fix_prs_total{outcome="merged"} rose by exactly one over the start count (the
#     reconciler, Task 4.3a), and Grafana panel 4's merged-count query returns the same value;
#     then the fix PR is labelled demo-reset (O23: test PRs never stay on panel 4) and both the
#     bridge and panel 4 fall back to the start count
#   - the Task 3.16 budget: T0 -> PR <= 150 s, merge -> Healthy <= 90 s, and the machine total
#     plus the budgeted human dwell (HUMAN_DWELL_S, 90 s) <= 330 s (spec §8, 5.5 min)
#
# The fix PR is merged by this script with `gh pr merge --merge` (Luke's gh login). With
# RUNG2_MERGE=browser it waits (up to BROWSER_MERGE_WAIT_S) for someone to merge it in the
# browser instead, then measures from GitHub's mergedAt the same way.
#
# RUNG2_KEEP_COUNT=1 leaves the fix PR unlabelled, so it stays counted on panel 4 (for the panel-4
# screenshot). Label it afterwards, or the next run's start count includes it:
#   gh api -X POST repos/<slug>/issues/<pr>/labels -f 'labels[]=demo-reset'
# A failed run labels a merged fix PR on its way out unless RUNG2_KEEP_COUNT=1.
#
# Timings: one "rung2:" line on stdout and a row in $EVIDENCE_DIR/slice-4/rung2-runs.tsv
# (EVIDENCE_DIR from .env or the caller, default <main checkout>/.evidence).
#
# Usage, from the main checkout: tests/e2e/rung2.sh
# Exit codes: 1 an assertion failed, 3 wrong context, 4 a wait timed out, 5 cluster lock held.

set -euo pipefail
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git-ops.sh
. "$E2E_DIR/../../scripts/git-ops.sh"
# shellcheck source=tests/e2e/assert.sh
. "$E2E_DIR/assert.sh"

PR_WAIT_S="${PR_WAIT_S:-300}"
DEGRADED_WAIT_S="${DEGRADED_WAIT_S:-180}"
HEALTHY_WAIT_S="${HEALTHY_WAIT_S:-240}"
BROWSER_MERGE_WAIT_S="${BROWSER_MERGE_WAIT_S:-900}"
MERGE_SYNC_MAX_S="${MERGE_SYNC_MAX_S:-30}"
T0_PR_MAX_S="${T0_PR_MAX_S:-150}"
MERGE_HEALTHY_MAX_S="${MERGE_HEALTHY_MAX_S:-90}"
HUMAN_DWELL_S="${HUMAN_DWELL_S:-90}"
SLOT_S="${SLOT_S:-330}"

now() { date +%s; }
step() { printf '\n== %s\n' "$*" >&2; }
fail() { log_error "rung2: $*"; exit 1; }

run_make() { # TARGET... : output to stderr and the run log, stdout returned
  local out rc=0
  out="$(make --no-print-directory -C "$ROOT" "$@" 2> >(tee -a "$RUN_LOG" >&2))" || rc=$?
  printf '%s\n' "$out" | tee -a "$RUN_LOG" >&2
  ((rc == 0)) || fail "make $* exited $rc"
  printf '%s\n' "$out"
}

run_promo() { # SUBCOMMAND ARGS... : scripts/promotion-pr.sh, same output handling
  local out rc=0
  out="$("$ROOT/scripts/promotion-pr.sh" "$@" 2> >(tee -a "$RUN_LOG" >&2))" || rc=$?
  printf '%s\n' "$out" | tee -a "$RUN_LOG" >&2
  ((rc == 0)) || fail "promotion-pr.sh $* exited $rc"
  printf '%s\n' "$out"
}

machine() { sed -n "s/^$1: //p" <<<"$2" | tail -n1; } # KEY TEXT

commit_time() { _og show -s --format=%ct "$1"; }

label_demo_reset() { # PR : REST, not `gh pr edit --add-label` (it fails on the classic-projects GraphQL field)
  gh api -X POST "repos/$REPO_SLUG/issues/$1/labels" -f "labels[]=demo-reset" >/dev/null
}

delete_remote_branch() { # BRANCH : best effort, through the API with the operator's gh login
  if gh api -X DELETE "repos/$REPO_SLUG/git/refs/heads/$1" >/dev/null 2>&1; then
    log_info "rung2: deleted branch $1"
  else
    log_warn "rung2: could not delete branch $1"
  fi
}

# ---------------------------------------------------------------- start state
lower_to_suggest() {
  op_sync
  while [[ "$(yaml_get "$AUTONOMY_FILE" .level)" != suggest ]]; do
    log_warn "rung2: autonomy is $(yaml_get "$AUTONOMY_FILE" .level) on $TRACKED_BRANCH; demoting (forward commit)"
    run_promo demote >/dev/null
    op_sync
  done
}

close_open_agent_prs() { # leftovers would make the bridge comment instead of opening a PR
  local n branch
  for n in $(open_agent_prs checkout); do
    branch="$(gh pr view "$n" --repo "$REPO_SLUG" --json headRefName --jq .headRefName)"
    label_demo_reset "$n"
    gh pr close "$n" --repo "$REPO_SLUG" --comment "closed by tests/e2e/rung2.sh (demo reset)" >/dev/null
    log_warn "rung2: closed leftover agent PR $n"
    delete_remote_branch "$branch"
  done
}

on_exit() {
  local rc=$?
  trap - EXIT
  if ((rc != 0)) && [[ -n "${RUN_LOG:-}" ]] && [[ "${RUNG2_NO_CLEANUP:-0}" != "1" ]]; then
    log_warn "rung2: failed (exit $rc); closing this run's open PRs and disarming to $CHECKOUT_STABLE_TAG"
    (close_open_agent_prs) || true
    if [[ -n "${FIX_PR:-}" && "${RUNG2_KEEP_COUNT:-0}" != 1 ]] && pr_state_is "$FIX_PR" MERGED; then
      if (label_demo_reset "$FIX_PR"); then
        log_warn "rung2: labelled merged fix PR $FIX_PR demo-reset (O23)"
      else
        log_error "rung2: could not label fix PR $FIX_PR demo-reset; label it by hand"
      fi
    fi
    if [[ -n "${PROMO_PR:-}" ]] && pr_state_is "$PROMO_PR" OPEN; then
      gh pr close "$PROMO_PR" --repo "$REPO_SLUG" --comment "closed by tests/e2e/rung2.sh (failed run)" >/dev/null || true
    fi
    [[ -n "${PROMO_BRANCH:-}" ]] && delete_remote_branch "$PROMO_BRANCH"
    (run_make disarm IMAGE="$CHECKOUT_STABLE_TAG" >/dev/null) \
      || log_error "rung2: the cleanup disarm failed too; run make disarm IMAGE=$CHECKOUT_STABLE_TAG"
  fi
  exit "$rc"
}

# ---------------------------------------------------------------- main
main() {
  (($# == 0)) || die "usage: tests/e2e/rung2.sh   (RUNG2_MERGE=browser to merge the fix PR by hand)"
  local merge_mode="${RUNG2_MERGE:-script}" keep_count="${RUNG2_KEEP_COUNT:-0}"
  [[ "$merge_mode" == script || "$merge_mode" == browser ]] || die "RUNG2_MERGE must be script or browser"
  [[ "$keep_count" == 0 || "$keep_count" == 1 ]] || die "RUNG2_KEEP_COUNT must be 0 or 1"
  load_env
  require_context
  ROOT="$(main_root)"
  [[ "$(cd "$E2E_DIR/../.." && pwd -P)" == "$(cd "$ROOT" && pwd -P)" ]] \
    || die "run rung2.sh from the main checkout ($ROOT), not a worktree"
  cluster_lock
  trap on_exit EXIT

  local evdir run_id
  evdir="${EVIDENCE_DIR:-$ROOT/.evidence}/slice-4"
  mkdir -p "$evdir"
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_LOG="$evdir/rung2-$run_id.log"
  : >"$RUN_LOG"
  log_info "rung2: run $run_id (fix PR merged by: $merge_mode), log $RUN_LOG"

  step "fresh bridge and sim code (Task 2.4)"
  run_make redeploy-bridge redeploy-sim >/dev/null
  "$ROOT/scripts/ensure-image.sh" --assert-running bridge || fail "bridge runs a stale image"
  "$ROOT/scripts/ensure-image.sh" --assert-running cdevents-sim || fail "cdevents-sim runs a stale image"
  wait_for "bridge /status answers" 60 bridge_status >/dev/null
  bridge_status | jq -e '.dry_forge == false and .github_token_ok == true and .holmes_reachable == true' >/dev/null \
    || { bridge_status >&2; fail "the bridge is not ready for real writes (dry_forge, GitHub token, HolmesGPT)"; }

  step "start state: suggest, no open agent PR, disarm --image $CHECKOUT_STABLE_TAG"
  lower_to_suggest
  close_open_agent_prs
  run_make disarm IMAGE="$CHECKOUT_STABLE_TAG" >/dev/null
  # O23: earlier test PRs carry demo-reset, so this is usually 0; the bridge must agree before the
  # run, or "rose by one" below proves nothing.
  local merged_series='aiops_fix_prs_total{outcome="merged"}' merged_start
  merged_start="$(merged_fix_prs_on_github checkout)"
  wait_for "the bridge's merged count equals GitHub's ($merged_start)" 90 \
    bridge_metric_is "$merged_series" "$merged_start" \
    || fail "the bridge's merged count is $(bridge_metric "$merged_series"), GitHub says $merged_start"
  log_info "rung2: merged fix PRs at the start: $merged_start"

  step "promotion PR to propose (fresh branch, Δ25)"
  local out head
  out="$(run_promo ensure propose)"
  PROMO_PR="$(machine pr "$out")"
  PROMO_BRANCH="$(machine branch "$out")"
  head="$(machine head "$out")"
  [[ "$PROMO_PR" =~ ^[0-9]+$ && "$PROMO_BRANCH" == promote/propose-* && "$head" =~ ^[0-9a-f]{40}$ ]] \
    || fail "ensure did not print pr, branch and head"
  [[ "$(gh pr diff "$PROMO_PR" --repo "$REPO_SLUG" --name-only)" == "$AUTONOMY_FILE" ]] \
    || fail "promotion PR $PROMO_PR does not change exactly $AUTONOMY_FILE"

  step "merge the promotion PR with admin bypass (D5), then record-approval"
  run_promo merge "$PROMO_PR" --admin >/dev/null
  pr_state_is "$PROMO_PR" MERGED || fail "promotion PR $PROMO_PR is not MERGED"
  delete_remote_branch "$PROMO_BRANCH"
  local t_rec0 t_rec1 approved
  t_rec0="$(now)"
  run_promo record-approval "$PROMO_PR" >/dev/null
  t_rec1="$(now)"
  wait_for "$AUTONOMY_FILE@$TRACKED_BRANCH is propose" 60 tracked_level_is propose
  approved="$(tracked_file "$AUTONOMY_FILE" | yq -r .promotion.approved_by)"
  log_info "rung2: approved_by: $approved"
  [[ "$approved" == admin-bypass || "$approved" =~ ^promotion-board\ member\ \(review\ https://github\.com/[^[:space:]]+\)$ ]] \
    || fail "approved_by is '$approved', not admin-bypass or a promotion-board review link"
  [[ "$approved" != *"${PROMOTION_TEAM#@}"* ]] || fail "approved_by names the team"
  if [[ "$approved" == *@* ]]; then fail "approved_by contains a login: $approved"; fi

  step "rearm (cause, then the bump: T0)"
  local t_rearm0 cause expected_ref bump t0
  t_rearm0="$(now)"
  out="$(run_make rearm)"
  cause="$(machine cause "$out")"
  expected_ref="$(machine change_ref "$out")"
  bump="$(machine bump "$out")"
  [[ "$cause" =~ ^[0-9a-f]{40}$ && "$bump" =~ ^[0-9a-f]{40}$ ]] || fail "rearm did not print cause and bump"
  t0="$(commit_time "$bump")"
  log_info "rung2: cause ${cause:0:7} ($expected_ref), bump ${bump:0:7}, T0 $t0"

  step "wait Degraded"
  wait_for "checkout Application Degraded" "$DEGRADED_WAIT_S" app_health_is checkout Degraded
  local t_deg hash_before
  t_deg="$(now)"
  hash_before="$(rollout_pod_hash)"

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
  assert_fix_pr_diff "$fix_pr" 2> >(tee -a "$RUN_LOG" >&2) \
    || fail "fix PR $fix_pr is not exactly two changed lines in the two files"
  gh pr diff "$fix_pr" --repo "$REPO_SLUG" | tee -a "$RUN_LOG" >&2
  assert_fix_pr_body "$body" "$cause" propose || fail "fix PR body: wrong or missing Cause line or footer"

  step "merge the fix PR ($merge_mode)"
  if [[ "$merge_mode" == script ]]; then
    gh pr merge "$fix_pr" --repo "$REPO_SLUG" --merge >/dev/null || fail "gh could not merge fix PR $fix_pr"
  else
    log_info "rung2: merge $fix_url in the browser now"
    wait_for "fix PR $fix_pr MERGED (in the browser)" "$BROWSER_MERGE_WAIT_S" pr_state_is "$fix_pr" MERGED
  fi
  # O13: the demo script forces the refresh as soon as it sees the merge (kubectl only).
  wait_for "fix PR $fix_pr MERGED" 30 pr_state_is "$fix_pr" MERGED
  k annotate application checkout -n "$NS_ARGOCD" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  local merge_sha t_merge t_synced
  merge_sha="$(gh pr view "$fix_pr" --repo "$REPO_SLUG" --json mergeCommit --jq .mergeCommit.oid)"
  t_merge="$(date -d "$(gh pr view "$fix_pr" --repo "$REPO_SLUG" --json mergedAt --jq .mergedAt)" +%s)"
  [[ "$merge_sha" =~ ^[0-9a-f]{40}$ ]] || fail "no merge commit for PR $fix_pr"
  local deadline=$(($(now) + MERGE_SYNC_MAX_S + 60))
  until app_synced_at checkout "$merge_sha"; do
    (($(now) < deadline)) || fail "Argo did not sync ${merge_sha:0:7} within $((MERGE_SYNC_MAX_S + 60))s of the merge"
    sleep 1
  done
  t_synced="$(now)"
  delete_remote_branch "$fix_branch"

  step "wait Healthy on a fresh canary"
  wait_for "checkout Application Healthy" "$HEALTHY_WAIT_S" app_health_is checkout Healthy
  local t_healthy
  t_healthy="$(now)"
  [[ "$(rollout_pod_hash)" != "$hash_before" ]] || fail "the Rollout's pod hash did not change after the fix"
  # Review Focus 5, checked again now: a duplicate (a webhook replay, a rehydrate miss) opens
  # seconds after the first PR, too late for the count above.
  n="$(agent_prs_since "$t0" checkout | grep -c . || true)"
  ((n == 1)) || fail "$n fix PRs from $BOT_LOGIN after T0 by Healthy, expected exactly one"

  step "timeline: change.created and the resolved incident"
  wait_for "change.created for checkout on /events since T0" 30 have_sim_event_since checkout change.created "$t0" \
    || fail "no change.created for checkout on /events"
  sim_events_since checkout change.created "$t0" | jq -e --arg u "$fix_url" 'select(.customData.pr_url == $u)' >/dev/null \
    || fail "the change.created event does not carry $fix_url"
  wait_for "the incident for ${bump:0:7} resolved on /incidents" 60 incident_resolved_for "$bump" \
    || fail "the incident is not resolved on /incidents"

  step "outcome counted (Task 4.3a) and shown on Grafana panel 4"
  # The reconciler sets the count from the full PR listing, so it must equal GitHub's own count,
  # and this run's merge is the only new one.
  local want panel4='sum(aiops_fix_prs_total{outcome="merged"}) or vector(0)'
  want="$(merged_fix_prs_on_github checkout)"
  ((want == merged_start + 1)) || fail "GitHub shows $want merged fix PRs, expected $merged_start + 1"
  wait_for "the bridge's $merged_series = $want" 90 \
    bridge_metric_is "$merged_series" "$want" || fail "the bridge's merged count is not $want"
  wait_for "Grafana panel 4 merged count = $want" 90 grafana_value_is "$panel4" "$want" \
    || fail "Grafana panel 4 merged count is $(grafana_prom_value "$panel4"), expected $want"
  log_info "rung2: merged fix PRs: $merged_start -> $want (GitHub, bridge, Grafana panel 4)"

  if [[ "$keep_count" == 1 ]]; then
    log_warn "rung2: RUNG2_KEEP_COUNT=1: fix PR $fix_pr stays counted on panel 4. After the screenshot:"
    log_warn "  gh api -X POST repos/$REPO_SLUG/issues/$fix_pr/labels -f 'labels[]=demo-reset'"
  else
    step "O23: label the fix PR demo-reset; panel 4 back to $merged_start"
    label_demo_reset "$fix_pr" || fail "could not label fix PR $fix_pr demo-reset"
    [[ "$(merged_fix_prs_on_github checkout)" == "$merged_start" ]] \
      || fail "GitHub still counts $(merged_fix_prs_on_github checkout) merged fix PRs after the label"
    wait_for "the bridge's $merged_series back to $merged_start" 90 \
      bridge_metric_is "$merged_series" "$merged_start" \
      || fail "the bridge's merged count is $(bridge_metric "$merged_series"), expected $merged_start after the label"
    wait_for "Grafana panel 4 merged count back to $merged_start" 90 grafana_value_is "$panel4" "$merged_start" \
      || fail "Grafana panel 4 merged count is $(grafana_prom_value "$panel4"), expected $merged_start after the label"
    log_info "rung2: fix PR $fix_pr labelled demo-reset; merged count back to $merged_start (bridge, panel 4)"
  fi
  local left
  left="$(open_agent_prs checkout | tr '\n' ' ')"
  [[ -z "$left" ]] || fail "open agent PRs left for checkout at the end: $left(one open agent PR per app)"

  local rec_s=$((t_rec1 - t_rec0)) rearm_s=$((t0 - t_rearm0)) t0_deg=$((t_deg - t0)) t0_pr=$((t_pr - t0))
  local deg_pr=$((t_pr - t_deg)) merge_synced=$((t_synced - t_merge)) synced_healthy=$((t_healthy - t_synced))
  local merge_healthy=$((t_healthy - t_merge)) machine_total total summary
  ((rearm_s >= 0)) || rearm_s=0
  machine_total=$((rec_s + rearm_s + t0_pr + merge_healthy))
  total=$((machine_total + HUMAN_DWELL_S))
  summary="rung2: run=$run_id merge=$merge_mode keep_count=$keep_count cause=${cause:0:7} promo_pr=$PROMO_PR fix_pr=$fix_pr record_approval_s=$rec_s rearm_s=$rearm_s t0_to_degraded_s=$t0_deg t0_to_pr_s=$t0_pr degraded_to_pr_s=$deg_pr merge_to_synced_s=$merge_synced synced_to_healthy_s=$synced_healthy merge_to_healthy_s=$merge_healthy machine_total_s=$machine_total with_dwell_s=$total approved_by=$approved"
  printf '%s\n' "$summary" | tee -a "$RUN_LOG"
  [[ -s "$evdir/rung2-runs.tsv" ]] \
    || printf 'run\tmerge\tcause\tpromo_pr\tfix_pr\trecord_approval_s\trearm_s\tt0_to_degraded_s\tt0_to_pr_s\tdegraded_to_pr_s\tmerge_to_synced_s\tsynced_to_healthy_s\tmerge_to_healthy_s\tmachine_total_s\twith_dwell_s\tfix_pr_url\n' >"$evdir/rung2-runs.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run_id" "$merge_mode" "$cause" "$PROMO_PR" \
    "$fix_pr" "$rec_s" "$rearm_s" "$t0_deg" "$t0_pr" "$deg_pr" "$merge_synced" "$synced_healthy" "$merge_healthy" \
    "$machine_total" "$total" "$fix_url" >>"$evdir/rung2-runs.tsv"

  ((merge_synced <= MERGE_SYNC_MAX_S)) || fail "merge -> synced ${merge_synced}s is over ${MERGE_SYNC_MAX_S}s"
  ((t0_pr <= T0_PR_MAX_S)) || fail "T0 -> PR ${t0_pr}s is over ${T0_PR_MAX_S}s (Task 3.16 budget)"
  ((merge_healthy <= MERGE_HEALTHY_MAX_S)) || fail "merge -> Healthy ${merge_healthy}s is over ${MERGE_HEALTHY_MAX_S}s"
  ((total <= SLOT_S)) || fail "machine ${machine_total}s + dwell ${HUMAN_DWELL_S}s = ${total}s is over ${SLOT_S}s"
  log_info "rung2: PASS"
}

main "$@"
