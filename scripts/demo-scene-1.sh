#!/usr/bin/env bash
# Scene 1, "2:19 Look, don't touch" (rung 1, suggest): the body of demo-rung-1.sh under a scene.
# Start from the end of the prologue (or `make reset-to-scene-1`). Environment: see demo-common.sh
# (DEMO_PACE, TYPE_SPEED, NO_WAIT, NARRATION_DIR). Narration keys: intro, push, gate, wait-teach,
# rca, fix, resolved.
set -euo pipefail
(($# == 0)) || { echo "usage: demo-scene-1.sh   (env: DEMO_PACE, TYPE_SPEED, NO_WAIT)" >&2; exit 2; }
# shellcheck source=scripts/demo-rung-1.sh
. "$(dirname "${BASH_SOURCE[0]}")/demo-rung-1.sh"

scene_init scene-1
scene_break "2:19 Look, don't touch"
scene_say intro
rung1_main
