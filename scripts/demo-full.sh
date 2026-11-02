#!/usr/bin/env bash
# The whole talk as one script (O31): cold open, prologue, scenes 1 to 3, epilogue, close. No
# reset between scenes: each starts where the one before ended, and `scripts/stage-day.sh morning`
# leaves the start state. Stops at the first scene that exits non-zero (exit 10 is a scene that
# ended early on a failure branch, for example "handoff: cut to clip") and returns its code.
# After a stop it prints how to carry on (draft section 5: the clip plays and the later scenes stay
# live): after scene N (1 or 2), `make reset-to-scene-(N+1)` while the clip plays, then
# `make demo-scene-(N+1)`; after scene 3, `make demo-epilogue` and `make demo-close`.
#
#   DEMO_PACE=talk (default)   Enter at scene_break, fourth_wall and speaker_beat only
#   DEMO_PACE=auto             no stdin, the e2e assertions run (set DEMO_AUTOMERGE_FOR_TEST=1 so the
#                              promotion PRs and the scene 2 fix PR are merged without a person)
#
# DEMO_SCENES_DIR (default: this directory) is where the demo-<scene>.sh scripts are, for tests.
set -euo pipefail
(($# == 0)) || { echo "usage: demo-full.sh   (env: DEMO_PACE, TYPE_SPEED, NO_WAIT)" >&2; exit 2; }

SCENES=(cold-open prologue scene-1 scene-2 scene-3 epilogue close)
dir="${DEMO_SCENES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# resume_hint SCENE : what the operator types next, one short line each (fits STAGE_COLS).
resume_hint() {
  case "$1" in
    scene-1 | scene-2)
      printf 'next: make reset-to-scene-%d\n' "$((${1#scene-} + 1))"
      printf 'then: make demo-scene-%d\n' "$((${1#scene-} + 1))"
      ;;
    scene-3) printf 'next: make demo-epilogue\nthen: make demo-close\n' ;;
    epilogue) printf 'next: make demo-close\n' ;;
  esac
}

for scene in "${SCENES[@]}"; do
  rc=0
  "$dir/demo-$scene.sh" || rc=$?
  if ((rc != 0)); then
    printf 'stopped: %s (exit %d)\n' "$scene" "$rc" >&2
    resume_hint "$scene" >&2
    exit "$rc"
  fi
done
