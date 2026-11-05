#!/usr/bin/env bash
# Scene 3, "2:31 Back in bed?" (rung 3, act): the act promotion (opened offstage by scene 2, or
# here when scene 2 left none), then the body of demo-rung-3.sh. `make night` is typed first and
# the teaching beat follows with no stop, so the 210-370 s wait runs under it (O32). Below propose (after an
# on-stage reject + demote) it refuses with exit 6: roll the clip. Narration keys: intro,
# promotion-read, board, policy, night, teach, pr, policy-pass, merged, healthy, verify,
# verify-read, recap.
set -euo pipefail
(($# == 0)) || { echo "usage: demo-scene-3.sh   (env: DEMO_PACE, TYPE_SPEED, NO_WAIT)" >&2; exit 2; }
# shellcheck source=scripts/demo-rung-3.sh
. "$(dirname "${BASH_SOURCE[0]}")/demo-rung-3.sh"

# act_promotion_pr : set ACT_PR to the number of an open act promotion PR; opens one (on screen)
# when there is none.
ACT_PR=""
act_promotion_pr() {
  local pr state=""
  pr="$(sed -n 's/^pr=//p' "$OPERATOR_STATE/promotion-act" 2>/dev/null | head -n1 || true)"
  if [[ "$pr" =~ ^[0-9]+$ ]]; then
    state="$(gh pr view "$pr" --repo "$REPO_SLUG" --json state --jq .state 2>/dev/null || true)"
  fi
  if [[ "$state" != OPEN ]]; then
    shown "scripts/promotion-pr.sh ensure act" "$PROMOTION_PR_SH" ensure act \
      || refuse 1 "no act promotion PR" "could not open the act promotion PR"
    pr="$(sed -n 's/^pr=//p' "$OPERATOR_STATE/promotion-act" 2>/dev/null | head -n1 || true)"
    [[ "$pr" =~ ^[0-9]+$ ]] || refuse 1 "no act promotion PR" "no act promotion PR recorded"
  fi
  ACT_PR="$pr"
}

scene_init scene-3
scene_break "2:31 Back in bed?"
scene_say intro
if ! tracked_level_is act; then
  tracked_level_is propose || refuse 6 "below propose; clip" "autonomy on $TRACKED_BRANCH is below propose; roll the clip"
  act_promotion_pr
  promote_to act "$ACT_PR"
  if [[ "$NO_WAIT" == true ]]; then check "approver is a role" approved_by_is_role; fi
fi
look "Browser, GitHub: policy/autofix.rego" "https://github.com/$REPO_SLUG/blob/$TRACKED_BRANCH/policy/autofix.rego"
scene_say policy # the guardrail, before it acts
rung3_main # types make night, then the teach narration runs under the wait (no stop)
