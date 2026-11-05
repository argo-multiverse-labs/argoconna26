#!/usr/bin/env bash
# Scene 2, "2:24 Hands made of Git" (rung 2, propose): the body of demo-rung-2.sh under a scene,
# then the act promotion PR is opened offstage for scene 3 (when the level is propose; after an
# on-stage reject + demote it is suggest, and scene 3 says so). Start from the end of scene 1
# (or `make reset-to-scene-2`). Narration keys: intro, promotion, board, incident-again, identity,
# fix-pr, review, merged, rejected, demote, act-offstage.
set -euo pipefail
(($# == 0)) || { echo "usage: demo-scene-2.sh   (env: DEMO_PACE, TYPE_SPEED, NO_WAIT)" >&2; exit 2; }
# shellcheck source=scripts/demo-rung-2.sh
. "$(dirname "${BASH_SOURCE[0]}")/demo-rung-2.sh"

# open_act_promotion : the offstage line. The PR it opens is the one scene 3 verifies and merges.
open_act_promotion() {
  if ! tracked_level_is propose; then
    beat "no act promotion yet"
    return 0
  fi
  if shown "scripts/promotion-pr.sh ensure act" "$PROMOTION_PR_SH" ensure act; then
    scene_say act-offstage
  else
    [[ "$NO_WAIT" == true ]] && { log_error "FAIL: act promotion PR not opened"; exit 1; }
    beat "act promotion: not open"
  fi
}

scene_init scene-2
scene_break "2:24 Hands made of Git"
scene_say intro
rung2_main
open_act_promotion
