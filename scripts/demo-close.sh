#!/usr/bin/env bash
# Close: the Grafana timeline where the signal now lives, the "It's in Slack" callback, the
# character drop, and the repo link. Narration keys: timeline, slack, drop, repo.
set -euo pipefail
(($# == 0)) || { echo "usage: demo-close.sh   (env: DEMO_PACE, TYPE_SPEED, NO_WAIT)" >&2; exit 2; }
# shellcheck source=scripts/demo-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/demo-common.sh"

scene_init close
title_card "2:31 a.m." "Back in bed by 2:30"
open_tab "$(grafana_kiosk_url)"
scene_say timeline
speaker_beat sre "it's in Slack, the callback"
scene_say slack
speaker_beat both "character drop; the landing line"
scene_say drop
beat "${REPO_SLUG%%/*}/"
beat "${REPO_SLUG#*/}"
scene_say repo
