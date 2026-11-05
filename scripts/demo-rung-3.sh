#!/usr/bin/env bash
# Rung 3 (act) as it is shown on stage: the scheduled job runs live, from the armed state. Start
# from `make reset-rung-3` plus the promotion to act (the On-call SRE's approval as the board, or an admin bypass),
# which happens before this script starts.
#
#   make night (the stage line is "running the nightly job now") -> the unit re-arms -> Degraded
#   at the bump -> the bot's fix PR -> policy-check -> merged by the bot (GitHub's auto-merge, or
#   the bridge's catch-up after ACT_AUTOMERGE_GRACE_S) with no human -> synced -> Healthy -> the
#   tabs open: the PR and its Checks tab (Argo CD and Grafana have their own tabs all talk).
#
# Nothing here holds the cluster lock (make night refuses under it), merges a PR, or nudges Argo
# (O13/O29). DEMO_AUTOMERGE_FOR_TEST and DEMO_REJECT_FOR_TEST are ignored on this rung.
# With NO_WAIT=true the script ends with overnight-verify.sh for the run it just made.
# Sourced by demo-scene-3.sh, which calls rung3_main under a scene (narration, scene pauses).
set -euo pipefail
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  (($# == 0)) || { echo "usage: demo-rung-3.sh   (env: TYPE_SPEED, NO_WAIT)" >&2; exit 2; }
fi
# shellcheck source=scripts/demo-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/demo-common.sh"

# unit_value KEY TEXT : the last "KEY: value" line of the unit's journal text.
unit_value() { sed -n "s/^$1: //p" <<<"$2" | tail -n1; }

bot_merged() { # PR : mergedBy is the bot (GitHub's auto-merge credits the app that enabled it)
  local by slug="${BOT_LOGIN%\[bot\]}"
  by="$(pr_merged_by "$1")"
  [[ "$by" == "$BOT_LOGIN" || "$by" == "$slug" || "$by" == "app/$slug" ]]
}

open_tabs() { # PR_URL : the fixed order
  open_tab "$1"
  open_tab "$1/checks"
}

rung3_main() {
  local run_ts journal cause bump ref conclusion merge_sha
  tracked_level_is act || refuse 6 "autonomy not act" "autonomy on $TRACKED_BRANCH is not act; promote first"

  rung_break "Rung 3: act"
  cue pe
  typed "make night" # prints "running the nightly job now"; refuses under a held lock
  run_ts="$(sed -n 's/^RUN_TS=//p' "$OPERATOR_STATE/last-run" 2>/dev/null | tail -n1)"
  [[ "$run_ts" =~ ^[0-9]+$ ]] || die "make night did not record RUN_TS"
  journal="$(journalctl --user -u argoconna26-rearm.service --since "@$run_ts" -o cat --no-pager 2>/dev/null || true)"
  cause="$(unit_value cause "$journal")"
  bump="$(unit_value bump "$journal")"
  ref="$(unit_value change_ref "$journal")"
  if ! sha_ok "$cause" || ! sha_ok "$bump"; then die "the job's journal has no cause and bump"; fi
  scene_say teach # O32: the On-call SRE teaches while the job re-arms and the agent works (no stop)

  READY_TIMEOUT_S="${DEGRADED_WAIT_S:-180}" until_ready "Degraded" degraded_at "$bump"
  beat "Degraded"
  READY_TIMEOUT_S="${OUTCOME_WAIT_S:-300}" await_outcome "$run_ts" 1 checkout "$cause" "$bump"
  unhappy_outcome || true
  require_fix_pr

  beat "bot PR #$OUT_PR"
  scene_say pr
  READY_TIMEOUT_S="${POLICY_WAIT_S:-600}" until_ready "policy-check" pr_policy_check_done "$OUT_PR"
  conclusion="$(pr_policy_check_conclusion "$OUT_PR")"
  if [[ "$conclusion" != success ]]; then
    beat "policy: left for review"
    open_tab "$OUT_URL/checks" # the policy working, shown as a feature
    # Under NO_WAIT the run needs the PR path through to Healthy: a failed check is a FAIL.
    [[ "$NO_WAIT" == true ]] && { log_error "FAIL: policy ${conclusion:-none}"; exit 1; }
    leave_early
  fi
  beat "policy-check: pass"
  scene_say policy-pass

  READY_TIMEOUT_S="${MERGED_WAIT_S:-900}" until_ready "auto-merge" pr_not_open "$OUT_PR"
  pr_state_is "$OUT_PR" MERGED \
    || refuse 1 "PR closed, not merged" "fix PR $OUT_PR was closed, not merged"
  bot_merged "$OUT_PR" || refuse 1 "merged by a person" "fix PR $OUT_PR was not merged by $BOT_LOGIN"
  beat "auto-merged"
  scene_say merged
  merge_sha="$(pr_merged_sha "$OUT_PR")"
  READY_TIMEOUT_S="${SYNC_WAIT_S:-120}" until_ready "synced" app_synced_at checkout "$merge_sha"
  beat "synced"
  READY_NOTE="canary, about 60s" READY_TIMEOUT_S="${HEALTHY_WAIT_S:-240}" until_ready "Healthy" app_health_is checkout Healthy
  beat "healthy"
  scene_say healthy
  open_tabs "$OUT_URL"
  if [[ -n "$SCENE" ]]; then
    scene_say verify
    show_verify "$run_ts" || { [[ "$NO_WAIT" == true ]] && exit 1; leave_early; }
  fi

  if [[ "$NO_WAIT" == true ]]; then
    check "fix PR is two lines" assert_fix_pr_diff "$OUT_PR"
    check "fix PR cites the cause" assert_fix_pr_body "$(pr_body "$OUT_PR")" "$cause" act "$ref"
    [[ -n "$SCENE" ]] || check "overnight-verify" quiet "$OVERNIGHT_VERIFY" "SINCE=$run_ts" "UNTIL=$(date +%s)"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then rung3_main; fi
