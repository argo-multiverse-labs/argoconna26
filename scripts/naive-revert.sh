#!/usr/bin/env bash
# The green-but-wrong demonstration (spec §6): revert the last image bump. The app goes
# green, and the security fix in that image is silently gone. Then an unrelated deploy
# trips the still-armed config again.
# Refuses unless HEAD is an image bump made by `bump` (subject and a higher tag), and
# unless the revert lands on a tag older than CHECKOUT_CVE_TAG, so "security fix is gone"
# is true. One short line per beat. NAIVE_STOP_AT_GREEN=1 stops after the first half.
set -euo pipefail
# shellcheck source=scripts/git-ops.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-ops.sh"

BUMP_SUBJECT_RE='^chore\(checkout\): bump image to v[0-9]+\.[0-9]+\.[0-9]+$'

# ver_lt A B : true when version A sorts before version B (vX.Y.Z).
ver_lt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

# The tag HEAD~1 has (what a revert of HEAD goes back to).
prev_image_tag() {
  _og show "HEAD~1:$KUSTOMIZATION_FILE" 2>/dev/null | yq -r "$_image_sel" 2>/dev/null
}

# True when HEAD is a bump: op_bump's subject, only the kustomization changed, and the
# checkout tag went up. A revert of a bump, or a disarm that only pins the image, is not.
head_is_image_bump() {
  local files before now
  [[ "$(_og log -1 --format=%s HEAD)" =~ $BUMP_SUBJECT_RE ]] || return 1
  files="$(_og diff-tree --no-commit-id --name-only -r HEAD)"
  [[ "$files" == "$KUSTOMIZATION_FILE" ]] || return 1
  before="$(prev_image_tag)" || return 1
  now="$(image_tag_get)"
  [[ -n "$before" ]] && ver_lt "$before" "$now"
}

main() {
  local revert_sha tag head_sha subject
  load_env
  require_context
  cluster_lock
  machine_init last-revert
  op_sync
  head_is_image_bump || refuse 1 "not an image bump" "naive-revert: HEAD is not an image bump"
  tag="$(prev_image_tag)"
  ver_lt "$tag" "$CHECKOUT_CVE_TAG" \
    || refuse 1 "revert keeps CVE fix" \
      "naive-revert: the revert lands on $tag, which already has the CVE fix ($CHECKOUT_CVE_TAG); run make disarm IMAGE=$CHECKOUT_STABLE_TAG and make rearm first"

  # --no-commit, then a normal commit, so the pre-commit hook runs on the revert too.
  head_sha="$(_og rev-parse HEAD)"
  subject="$(_og log -1 --format=%s HEAD)"
  _ogq revert --no-commit HEAD
  revert_sha="$(op_commit_push "Revert \"$subject\""$'\n\n'"This reverts commit $head_sha." "$KUSTOMIZATION_FILE")"
  [[ "$(image_tag_get)" == "$tag" ]] || die "naive-revert: image is $(image_tag_get) after the revert, expected $tag"
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
