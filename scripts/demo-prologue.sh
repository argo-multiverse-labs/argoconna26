#!/usr/bin/env bash
# Prologue, "2:17 Synced. Healthy. On fire.": Argo CD all green, the Grafana timeline with the
# delivery events beside the SLO, the golden-path labels, and the fourth wall on Notifications and
# CDEvents. Narration keys: intro, timeline, golden-path, data, cdevents, rfc.
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

scene_init prologue
scene_break "2:17 Synced. Healthy. On fire."
scene_say intro
open_tab "$(argo_app_url)"
if all_apps_synced_healthy; then
  beat "Argo CD: all green"
else
  beat "Argo CD: not green"
  [[ "$NO_WAIT" == true ]] && exit 1
fi
beat "autonomy: $(tracked_file "$AUTONOMY_FILE" | yq -r .level)"
open_tab "$(grafana_kiosk_url)"
scene_say timeline
beat "owner: $(rollout_label example.dev/owner)"
beat "tier: $(rollout_label example.dev/tier)"
beat "slo: $(rollout_label slo.example.dev/success-rate)"
scene_say golden-path
speaker_beat sre "data and the golden path"
scene_say data
fourth_wall "Notifications and CDEvents"
scene_say cdevents
scene_say rfc
