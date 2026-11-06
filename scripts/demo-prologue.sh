#!/usr/bin/env bash
# Prologue, "2:17 What changed?", out of character: where the answer to "what changed?" lives.
# Argo CD all green, the Grafana timeline with the delivery events (CDEvents) beside the SLO, the
# PR-242 timeout change read from the live ConfigMap, the golden-path labels behind the On-call
# SRE's point about data, and the trust ladder the rest of the talk climbs. Argo CD and Grafana
# are already open in their own browser tabs, so the look cues open nothing.
# Narration keys: intro, argo, timeline, pr242, pr242-read, data, data-after, ladder.
set -euo pipefail
(($# == 0)) || { echo "usage: demo-prologue.sh   (env: DEMO_PACE, TYPE_SPEED, NO_WAIT)" >&2; exit 2; }
# shellcheck source=scripts/demo-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/demo-common.sh"

# rollout_label KEY : a label of the checkout Rollout, "?" when absent.
rollout_label() {
  local v
  v="$(k get rollout checkout -n "$NS_DEMO" -o "jsonpath={.metadata.labels.${1//./\\.}}" 2>/dev/null || true)"
  printf '%s' "${v:-?}"
}

# live_timeout : the timeout line of the live ConfigMap, as the grep on screen prints it.
live_timeout() {
  k get configmap checkout-config -n "$NS_DEMO" -o yaml 2>/dev/null \
    | grep -m1 "^  $CONFIG_KEY:" || beat "$CONFIG_KEY: ?"
}

scene_init prologue
scene_break "2:17 What changed?"
scene_say intro
look "Browser, Argo CD: the applications"
if all_apps_synced_healthy; then
  beat "Argo CD: all green"
else
  beat "Argo CD: not green"
  [[ "$NO_WAIT" == true ]] && exit 1
fi
scene_say argo
look "Browser, Grafana: the top panel"
scene_say timeline
scene_say pr242
shown "kubectl get configmap checkout-config -n $NS_DEMO -o yaml | grep TIMEOUT" live_timeout
scene_say pr242-read
speaker_beat sre "data and the golden path"
scene_say data
beat "owner: $(rollout_label example.dev/owner)"
beat "tier: $(rollout_label example.dev/tier)"
beat "slo: $(rollout_label slo.example.dev/success-rate)"
scene_say data-after
scene_say ladder
beat "autonomy: $(tracked_file "$AUTONOMY_FILE" | yq -r .level)"
