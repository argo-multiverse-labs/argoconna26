#!/usr/bin/env bash
# Re-arm the incident: the PR-242 timeout again (200, config-version untouched) as its own
# revision, wait until Argo has synced it, then bump the image (the deploy that gets aborted).
# Refuses (exit 7) when the tracked HEAD is already armed: the first commit would be empty
# and there would be no new revision to wait for.
# Prints (or, under STAGE=1, writes to .operator/last-rearm):
#   cause: <40hex>   bump: <40hex>   change_ref: CHG-XXXXXX
set -euo pipefail
# shellcheck source=scripts/git-ops.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-ops.sh"

main() {
  local n cause_sha change_ref subject="PR-242 replay: tune upstream timeout"
  load_env
  require_context
  cluster_lock
  machine_init last-rearm
  op_sync
  if [[ "$(config_value_get)" == "$CONFIG_ARMED" ]]; then
    refuse 7 "already armed" "rearm: already armed; run make disarm first"
  fi

  n="$(( $(_og log --format=%H --grep='^Demo-Rearm: ' | wc -l) + 1 ))"
  change_ref="$(new_change_ref)"
  config_value_set "$CONFIG_ARMED"
  cause_sha="$(op_commit_push "$subject"$'\n\n'"Demo-Rearm: $n" "$CONFIG_FILE")"
  beat "pushed: timeout $CONFIG_ARMED"
  emit_change_event "$cause_sha" config "$subject" "$change_ref"
  argo_refresh_and_wait checkout "$cause_sha"
  beat "synced"

  op_bump
  machine_line cause "$cause_sha"
  machine_line bump "$BUMP_SHA"
  machine_line change_ref "$change_ref"
}

main "$@"
