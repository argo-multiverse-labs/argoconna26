#!/usr/bin/env bash
# Rung 2 (propose) as it is shown on stage. Start from `make reset-rung-2` (autonomy suggest, a
# fresh promotion PR to propose is open, the fleet is disarmed).
#
#   verify the promotion PR -> it is merged (the On-call SRE approves as the board, the Platform Engineer merges) -> record
#   the approval -> make rearm -> Degraded -> the agent's fix PR -> merged (the On-call SRE's beat) ->
#   refresh -> synced -> Healthy.
#   If the fix PR is closed instead: rejected -> make demote -> autonomy suggest and the
#   rejected count up -> the human fix -> Healthy.
#
# A refusal, a PII block or a handoff is shown as a feature, not a failure (see demo-common.sh).
# With NO_WAIT=true, DEMO_AUTOMERGE_FOR_TEST=1 merges the bot's fix PR from a background helper
# and DEMO_REJECT_FOR_TEST=1 closes it; the promotion PR is merged by whoever runs the check
# (promotion-pr.sh merge --admin). The script ends with its assertions.
# Sourced by demo-scene-2.sh, which calls rung2_main under a scene (narration, scene pauses).
set -euo pipefail
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  (($# == 0)) || { echo "usage: demo-rung-2.sh   (env: TYPE_SPEED, NO_WAIT)" >&2; exit 2; }
fi
# shellcheck source=scripts/demo-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/demo-common.sh"

REJECTED_SERIES='aiops_fix_prs_total{outcome="rejected"}'

# The fix PR was closed: demote, wait on conditions that need no new incident, fix by hand.
rejected_branch() {
  local want
  want="$(awk -v a="$1" 'BEGIN {printf "%d", a + 1}')"
  beat "rejected: demoting"
  scene_say rejected
  speaker_beat pe "the safety valve"
  typed "make demote"
  until_ready "autonomy suggest" tracked_level_is suggest
  until_ready "rejected count up" bridge_metric_at_least "$REJECTED_SERIES" "$want"
  beat "autonomy: suggest"
  human_fix # the On-call SRE's beat
  if [[ "$NO_WAIT" == true ]]; then
    check "autonomy is suggest" tracked_level_is suggest
    check "rejected count rose" bridge_metric_at_least "$REJECTED_SERIES" "$want"
  fi
}

merged_branch() { # PR CAUSE REF
  local merge_sha
  refresh_checkout # O13: as soon as the merge is seen, kubectl only
  merge_sha="$(pr_merged_sha "$1")"
  beat "merged"
  scene_say merged
  until_ready "synced" app_synced_at checkout "$merge_sha"
  beat "synced"
  READY_NOTE="canary, about 60s" READY_TIMEOUT_S="${HEALTHY_WAIT_S:-240}" until_ready "Healthy" app_health_is checkout Healthy
  beat "healthy"
  if [[ "$NO_WAIT" == true ]]; then
    check "approver is a role" approved_by_is_role
    check "fix PR is two lines" assert_fix_pr_diff "$1"
    check "fix PR cites the cause" assert_fix_pr_body "$(pr_body "$1")" "$2" propose "$3"
  fi
}

rung2_main() {
  local promo cause ref bump t0 rejected_start
  promo="$(sed -n 's/^pr=//p' "$OPERATOR_STATE/promotion-propose" 2>/dev/null | head -n1)"
  [[ "$promo" =~ ^[0-9]+$ ]] || refuse 1 "no promotion PR" "no promotion PR recorded; run make reset-rung-2 first"

  rung_break "Rung 2: propose"
  scene_say promotion
  promote_to propose "$promo"
  rejected_start="$(bridge_metric "$REJECTED_SERIES")"

  t0="$(date +%s)"
  start_pr_helper "$t0"
  as_platform_engineer
  scene_say incident-again
  typed "make rearm"
  cause="$(machine_value last-rearm cause)"
  ref="$(machine_value last-rearm change_ref)"
  bump="$(machine_value last-rearm bump)"
  if ! sha_ok "$cause" || ! sha_ok "$bump"; then die "make rearm did not record the cause and the bump"; fi

  READY_TIMEOUT_S="${DEGRADED_WAIT_S:-180}" until_ready "Degraded" degraded_at "$bump"
  beat "Degraded"
  scene_say identity # the Platform Engineer covers the agent's identity and the bridge while the agent works
  READY_TIMEOUT_S="${OUTCOME_WAIT_S:-300}" await_outcome "$t0" 1 checkout "$cause" "$bump"
  unhappy_outcome || true
  if [[ "$OUT_KIND" != pr ]]; then
    beat "no fix PR, only a comment"
    open_tab "$OUT_URL"
    [[ "$NO_WAIT" == true ]] && exit 1
    leave_early
  fi

  beat "bot PR #$OUT_PR"
  open_tab "$OUT_URL"
  scene_say fix-pr
  speaker_beat sre "reviews the fix PR"
  scene_say review
  READY_TIMEOUT_S="${FIX_PR_WAIT_S:-900}" until_ready "PR merged" pr_not_open "$OUT_PR"
  if [[ "$(gh pr view "$OUT_PR" --repo "$REPO_SLUG" --json state --jq .state)" == MERGED ]]; then
    merged_branch "$OUT_PR" "$cause" "$ref"
  else
    rejected_branch "$rejected_start"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then rung2_main; fi
