#!/usr/bin/env bash
# The real fix: the timeout back to 2000 and config-version +1, in one commit, so the new
# pod template rolls the fleet. Exactly two values change.
set -euo pipefail
# shellcheck source=scripts/git-ops.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-ops.sh"

main() {
  local sha subject="fix(checkout): restore upstream timeout and roll config"
  load_env
  require_context
  cluster_lock
  machine_init last-fix
  op_sync
  if [[ "$(config_value_get)" == "$CONFIG_HEALTHY" ]]; then
    refuse 1 "already fixed" "fix: ${CONFIG_KEY} is already ${CONFIG_HEALTHY}; nothing to fix"
  fi
  config_value_set "$CONFIG_HEALTHY"
  config_version_bump >/dev/null # every pod restarts and reads the value again
  sha="$(op_commit_push "$subject" "$CONFIG_FILE" "$ROLLOUT_FILE")"
  beat "pushed: timeout $CONFIG_HEALTHY, restart"
  emit_change_event "$sha" config "$subject" ""
  argo_refresh_and_wait checkout "$sha"
  beat "synced"
  machine_line fix "$sha"
}

main "$@"
