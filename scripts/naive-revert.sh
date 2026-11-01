#!/usr/bin/env bash
# The green-but-wrong demonstration (spec §6): revert the last image bump. The app goes
# green, and the security fix in that image is silently gone. Then an unrelated deploy
# trips the still-armed config again.
# Refuses unless HEAD is an image bump. One short line per beat. NAIVE_STOP_AT_GREEN=1
# stops after the first half.
set -euo pipefail
# shellcheck source=scripts/git-ops.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-ops.sh"

# True when HEAD changed only the kustomization, and only its checkout tag.
head_is_image_bump() {
  local files before now
  files="$(_og diff-tree --no-commit-id --name-only -r HEAD)"
  [[ "$files" == "$KUSTOMIZATION_FILE" ]] || return 1
  before="$(_og show "HEAD~1:$KUSTOMIZATION_FILE" 2>/dev/null | yq -r "$_image_sel" 2>/dev/null)" || return 1
  now="$(image_tag_get)"
  [[ -n "$before" && "$before" != "$now" ]]
}

main() {
  local revert_sha tag
  load_env
  require_context
  cluster_lock
  machine_init last-run
  op_sync
  head_is_image_bump || die "naive-revert: HEAD is not an image bump"

  GIT_EDITOR=true _ogq revert --no-edit HEAD
  op_push
  revert_sha="$(_og rev-parse HEAD)"
  tag="$(image_tag_get)"
  beat "pushed: revert"
  emit_change_event "$revert_sha" revert "revert image bump" ""
  argo_refresh_and_wait checkout "$revert_sha"
  op_wait_health checkout Healthy
  beat "green: image back to $tag"
  beat "security fix is gone"
  machine_line revert "$revert_sha"
  [[ "${NAIVE_STOP_AT_GREEN:-0}" != "1" ]] || return 0

  op_bump
  machine_line bump "$BUMP_SHA"
  op_wait_health checkout Degraded "${DEGRADED_WAIT_S:-180}"
  beat "aborted again: still armed"
}

main "$@"
