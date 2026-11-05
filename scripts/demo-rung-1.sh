#!/usr/bin/env bash
# Rung 1 (suggest) as it is shown on stage. Start from `make reset-rung-1` (PR-242 is committed,
# the fleet is disarmed, autonomy is suggest).
#
#   make bump (the innocent release) -> the canary -> Degraded at the bump -> the agent's RCA
#   comment on the cause commit -> the On-call SRE's beat -> make fix -> Healthy -> the incident
#   is resolved.
#
# A refusal, a PII block or a handoff is shown as a feature, not a failure (see demo-common.sh).
# TYPE_SPEED and NO_WAIT are described in demo-common.sh. With NO_WAIT=true the script ends
# with its assertions: the RCA comment names the cause, has its Cause: line, 200 against 2000
# and the cause's change_ref.
# Sourced by demo-scene-1.sh, which calls rung1_main under a scene (narration, scene pauses).
set -euo pipefail
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  (($# == 0)) || { echo "usage: demo-rung-1.sh   (env: TYPE_SPEED, NO_WAIT)" >&2; exit 2; }
fi
# shellcheck source=scripts/demo-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/demo-common.sh"

rung1_main() {
  local cause ref bump t0
  cause="$(machine_value last-rearm cause)"
  ref="$(machine_value last-rearm change_ref)"
  sha_ok "$cause" || refuse 1 "no seeded cause" "no seeded cause in $OPERATOR_STATE/last-rearm; run make reset-rung-1 first"
  tracked_level_is suggest || refuse 1 "autonomy not suggest" "autonomy on $TRACKED_BRANCH is not suggest; run make reset-rung-1"

  rung_break "Rung 1: suggest"
  scene_say push
  t0="$(date +%s)"
  typed "make bump"
  bump="$(machine_value last-bump bump)"
  sha_ok "$bump" || die "make bump did not record the bump commit"
  scene_say canary # new pods read the new timeout; how the canary is checked
  look "Browser, Argo CD: checkout, the canary"

  READY_TIMEOUT_S="${DEGRADED_WAIT_S:-180}" until_ready "Degraded" degraded_at "$bump"
  beat "Degraded"
  scene_say gate
  scene_say handover
  speaker_beat sre "read-only by default; dry runs"
  scene_say wait-teach # the On-call SRE teaches while the agent works
  READY_TIMEOUT_S="${OUTCOME_WAIT_S:-300}" await_outcome "$t0" 0 checkout "$cause" "$bump"
  unhappy_outcome || true

  beat "agent: comment posted"
  look "Browser, GitHub: the agent's comment" "$OUT_URL"
  scene_say rca
  scene_say naive
  scene_say fix
  human_fix # the On-call SRE types make fix; after-fix narration inside
  look "Browser, Grafana: the success rate"
  until_ready "incident resolved" incident_resolved_for "$bump"
  beat "incident resolved"
  scene_say resolved
  scene_say recap

  if [[ "$NO_WAIT" == true ]]; then
    check "RCA names the cause" assert_rca_body "$OUT_BODY" "$cause" "$ref"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then rung1_main; fi
