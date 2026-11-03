#!/usr/bin/env bash
# Cold open, in character: the 5:00 p.m. mandate, then the 2:15 a.m. page. The terminal shows the
# platform's real state (autonomy level, the bridge) and nothing staged. "It's in Slack" is set up
# here and lands in demo-close.sh. Narration keys: mandate, bolted-on, page, what-changed, slack.
set -euo pipefail
(($# == 0)) || { echo "usage: demo-cold-open.sh   (env: DEMO_PACE, TYPE_SPEED, NO_WAIT)" >&2; exit 2; }
# shellcheck source=scripts/demo-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/demo-common.sh"

bridge_up() { curl -sf --max-time 5 "127.0.0.1:${PORT_BRIDGE}/status" >/dev/null; }

scene_init cold-open
title_card "5:00 p.m." "We Use AI Now"
scene_say mandate
beat "autonomy: $(tracked_file "$AUTONOMY_FILE" | yq -r .level)"
if bridge_up; then beat "bridge: up"; else beat "bridge: down"; fi
scene_say bolted-on
if [[ "$NO_WAIT" == true ]]; then
  check "autonomy is suggest" tracked_level_is suggest
  check "bridge is up" bridge_up
fi
title_card "2:15 a.m." "The page"
speaker_beat sre "paged at 2:15; what changed?"
scene_say page
scene_say what-changed
speaker_beat pe "it's in Slack"
scene_say slack
