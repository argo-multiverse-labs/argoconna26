#!/usr/bin/env bash
# Scene 3, "2:31 Back in bed?" (rung 3, act): the act promotion (opened offstage by scene 2, or
# here when scene 2 left none), then the body of demo-rung-3.sh. `make night` is typed first and
# the teaching beat follows with no stop, so the 210-370 s wait runs under it (O32). Below propose (after an
# on-stage reject + demote) it refuses with exit 6: roll the clip. Narration keys: intro, board,
# policy, teach, pr, policy-pass, merged, healthy, verify.
set -euo pipefail
(($# == 0)) || { echo "usage: demo-scene-3.sh   (env: DEMO_PACE, TYPE_SPEED, NO_WAIT)" >&2; exit 2; }
# shellcheck source=scripts/demo-rung-3.sh
. "$(dirname "${BASH_SOURCE[0]}")/demo-rung-3.sh"

# act_promotion_pr : the number of an open act promotion PR; opens one when there is none.
act_promotion_pr() {
  local pr state=""
  pr="$(sed -n 's/^pr=//p' "$OPERATOR_STATE/promotion-act" 2>/dev/null | head -n1)"
  if [[ "$pr" =~ ^[0-9]+$ ]]; then
    state="$(gh pr view "$pr" --repo "$REPO_SLUG" --json state --jq .state 2>/dev/null || true)"
  fi
  if [[ "$state" != OPEN ]]; then
    "$PROMOTION_PR_SH" ensure act >&2 || refuse 1 "no act promotion PR" "could not open the act promotion PR"
    pr="$(sed -n 's/^pr=//p' "$OPERATOR_STATE/promotion-act" 2>/dev/null | head -n1)"
    [[ "$pr" =~ ^[0-9]+$ ]] || refuse 1 "no act promotion PR" "no act promotion PR recorded"
  fi
  printf '%s\n' "$pr"
}

scene_init scene-3
scene_break "2:31 Back in bed?"
scene_say intro
speaker_beat sre "time is compressed; the bar"
if ! tracked_level_is act; then
  tracked_level_is propose || refuse 6 "below propose; clip" "autonomy on $TRACKED_BRANCH is below propose; roll the clip"
  act_pr="$(act_promotion_pr)"
  promote_to act "$act_pr"
  if [[ "$NO_WAIT" == true ]]; then check "approver is a role" approved_by_is_role; fi
fi
open_tab "https://github.com/$REPO_SLUG/blob/$TRACKED_BRANCH/policy/autofix.rego" # the guardrail, before it acts
scene_say policy
rung3_main # types make night, then the teach narration runs under the wait (no stop)
