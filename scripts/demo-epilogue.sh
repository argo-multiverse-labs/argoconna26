#!/usr/bin/env bash
# Epilogue, "What's real": panel 4 (touch-points per level), the verifier output from scene 3
# (kept in .operator/last-verify), the honest framing, and `make demote` back to suggest as the
# safety valve. Narration keys: panel, verifier, real, real-list, simulated, valve, safe.
set -euo pipefail
(($# == 0)) || { echo "usage: demo-epilogue.sh   (env: DEMO_PACE, TYPE_SPEED, NO_WAIT)" >&2; exit 2; }
# shellcheck source=scripts/demo-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/demo-common.sh"

level_is_not() { ! tracked_level_is "$1"; } # LEVEL

replay_verify() {
  local line
  if [[ -s "$OPERATOR_STATE/last-verify" ]]; then
    while IFS= read -r line; do beat "$line"; done <"$OPERATOR_STATE/last-verify"
  else
    beat "no verifier run yet"
  fi
}

# demote_to_suggest : make demote lowers one step at a time (act needs two).
demote_to_suggest() {
  local i level
  for i in 1 2 3; do
    ! tracked_level_is suggest || break
    level="$(tracked_file "$AUTONOMY_FILE" | yq -r .level)"
    typed "make demote"
    until_ready "autonomy lowered" level_is_not "$level"
  done
  tracked_level_is suggest || refuse 1 "autonomy not suggest" "autonomy is still not suggest after $i demotions"
  beat "autonomy: suggest"
}

scene_init epilogue
scene_break "What's real"
look "Browser, Grafana: human steps per incident"
scene_say panel
scene_say verifier
replay_verify
fourth_wall "Real, and stood in"
speaker_beat sre "what's real"
scene_say real
speaker_beat pe "real, and stood in"
scene_say real-list
scene_say simulated
speaker_beat sre "the safety valve"
scene_say valve
speaker_beat pe "make demote"
demote_to_suggest
scene_say safe
