#!/usr/bin/env bash
# The real fix: the timeout back to 2000 and config-version +1, in one commit, so the new
# pod template rolls the fleet. Exactly two values change.
set -euo pipefail
# shellcheck source=scripts/git-ops.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-ops.sh"

main() {
  local sha cv subject="fix(checkout): restore upstream timeout and roll config"
  load_env
  require_context
  cluster_lock
  machine_init last-run
  op_sync
  if [[ "$(config_value_get)" == "$CONFIG_HEALTHY" ]]; then
    die "fix: ${CONFIG_KEY} is already ${CONFIG_HEALTHY}; nothing to fix"
  fi
  config_value_set "$CONFIG_HEALTHY"
  cv="$(config_version_bump)"
  sha="$(op_commit_push "$subject" "$CONFIG_FILE" "$ROLLOUT_FILE")"
  beat "pushed: config $CONFIG_HEALTHY, cv $cv"
  emit_change_event "$sha" config "$subject" ""
  argo_refresh_and_wait checkout "$sha"
  beat "synced"
  machine_line fix "$sha"
}

main "$@"
