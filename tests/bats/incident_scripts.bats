#!/usr/bin/env bats
# Tests for seed-history, bump, rearm, fix, naive-revert and disarm (bare-repo fixture;
# git, kubectl, argocd and ensure-image are stubs, see ops_helpers.bash).

bats_require_minimum_version 1.5.0
load helpers
load ops_helpers

CFG=apps/checkout/config/checkout-config.yaml
ROLL=apps/checkout/deploy/rollout.yaml
KUST=apps/checkout/kustomization.yaml

setup() {
  make_ops_fixture
  STAGE_COLS="$(sed -n 's/^STAGE_COLS=//p' "$REPO_ROOT/demo.env")"
}

# other_commit MSG FILE KEY VALUE : another pusher edits origin directly (yq, as the scripts do).
other_commit() {
  "$REAL_GIT" -C "$OTHER" pull -q --ff-only origin build/demo
  V="$4" yq -i "$3 = strenv(V)" "$OTHER/$2"
  "$REAL_GIT" -C "$OTHER" commit -q -am "$1"
  "$REAL_GIT" -C "$OTHER" push -q origin HEAD:refs/heads/build/demo
}
arm_origin() { other_commit "test: armed" "$CFG" .data.UPSTREAM_TIMEOUT_MS 200; }

# events : the ordered stub events, space separated
events() { awk '{print $1}' "$CALLS" | grep -E '^(PUSH|ANNOTATE|REV|HEALTH|ENSURE)$' | tr '\n' ' '; }

cfg_value() { origin_file "$CFG" | yq -r .data.UPSTREAM_TIMEOUT_MS; }
cv_value()  { origin_file "$ROLL" | yq -r '.spec.template.metadata.annotations["example.dev/config-version"]'; }
tag_value() { origin_file "$KUST" | yq -r '.images[0].newTag'; }
commit_files() { "$REAL_GIT" --git-dir="$ORIGIN" diff-tree --no-commit-id --name-only -r "$1" | tr '\n' ' '; }

@test "seed refuses when tracked branch is armed and cluster not disarmed" {
  arm_origin
  run ops_run "$REPO_ROOT/scripts/seed-history.sh"
  [ "$status" -eq 0 ]
  # the disarm commit comes before the PR-242 commit
  run origin_log
  [ "${lines[0]}" = "docs: pricing service notes" ]
  [ "${lines[1]}" = "PR-242: tune upstream timeout for faster failover" ]
  [ "${lines[2]}" = "chore(demo): disarm checkout" ]
  [ "${lines[3]}" = "test: armed" ]
  # and it waited for Healthy before going on
  first_push="$(grep -n '^PUSH' "$CALLS" | head -1 | cut -d: -f1)"
  health="$(grep -n '^HEALTH' "$CALLS" | head -1 | cut -d: -f1)"
  second_push="$(grep -n '^PUSH' "$CALLS" | sed -n 2p | cut -d: -f1)"
  [ "$first_push" -lt "$health" ]
  [ "$health" -lt "$second_push" ]
}

@test "seed refuses to commit PR-242 when the cluster does not reach Healthy after the disarm" {
  arm_origin
  echo Degraded > "$STUBS/FORCE_HEALTH"
  export HEALTH_WAIT_S=2
  run ops_run "$REPO_ROOT/scripts/seed-history.sh"
  [ "$status" -eq 4 ]
  run origin_log
  [ "${lines[0]}" = "chore(demo): disarm checkout" ]
  [[ "$output" != *"PR-242"* ]]
}

@test "seed-history leaves config-version unchanged on PR-242" {
  run ops_run "$REPO_ROOT/scripts/seed-history.sh"
  [ "$status" -eq 0 ]
  [ "$(cfg_value)" = "200" ]
  [ "$(cv_value)" = "7" ]
  [ "$(tag_value)" = "v1.4.1" ]            # it stops before the bump
  pr="$(sed -n 's/^cause: //p' <<<"$output")"
  [[ "$pr" =~ ^[0-9a-f]{40}$ ]]
  [ "$(commit_files "$pr")" = "$CFG " ]
  "$REAL_GIT" --git-dir="$ORIGIN" log -1 --format=%B "$pr" | grep -q '^Demo-Seed: pr-242$'
  [ "$(commit_files refs/heads/build/demo)" = "apps/pricing/README.md " ]
  [[ "$output" =~ change_ref:\ CHG-[A-Z2-7]{6} ]]
  # the second seed disarms first and makes the same two commits again
  run ops_run "$REPO_ROOT/scripts/seed-history.sh"
  [ "$status" -eq 0 ]
  [ "$(cfg_value)" = "200" ]
  [ "$(cv_value)" = "8" ]                  # only the disarm bumped it
}

@test "rearm waits for config sync before bump" {
  run ops_run "$REPO_ROOT/scripts/rearm.sh"
  [ "$status" -eq 0 ]
  # push config, refresh, wait for that SHA, then ensure-image + the bump push, refresh, wait
  [ "$(events)" = "PUSH ANNOTATE REV ENSURE PUSH ANNOTATE REV " ]
  run origin_log
  [ "${lines[0]}" = "chore(checkout): bump image to v1.4.2" ]
  [ "${lines[1]}" = "PR-242 replay: tune upstream timeout" ]
  grep -q '^ENSURE checkout v1.4.2' "$CALLS"
}

@test "rearm prints cause, bump and change_ref, and tags the replay with a counter" {
  run ops_run "$REPO_ROOT/scripts/rearm.sh"
  [ "$status" -eq 0 ]
  cause="$(sed -n 's/^cause: //p' <<<"$output")"
  bump="$(sed -n 's/^bump: //p' <<<"$output")"
  [[ "$cause" =~ ^[0-9a-f]{40}$ ]]
  [[ "$bump" =~ ^[0-9a-f]{40}$ ]]
  [ "$bump" = "$(origin_tip)" ]
  [ "$(commit_files "$cause")" = "$CFG " ]         # config only: config-version untouched
  [ "$(cv_value)" = "7" ]
  "$REAL_GIT" --git-dir="$ORIGIN" log -1 --format=%B "$cause" | grep -q '^Demo-Rearm: 1$'
  ops_run "$REPO_ROOT/scripts/git-ops.sh" disarm >/dev/null
  run ops_run "$REPO_ROOT/scripts/rearm.sh"
  [ "$status" -eq 0 ]
  cause2="$(sed -n 's/^cause: //p' <<<"$output")"
  "$REAL_GIT" --git-dir="$ORIGIN" log -1 --format=%B "$cause2" | grep -q '^Demo-Rearm: 2$'
}

@test "rearm on an armed branch refuses and pushes nothing" {
  arm_origin
  tip="$(origin_tip)"
  run ops_run "$REPO_ROOT/scripts/rearm.sh"
  [ "$status" -eq 7 ]
  [[ "$output" == *"rearm: already armed; run make disarm first"* ]]
  [ "$(origin_tip)" = "$tip" ]
  ! grep -q '^PUSH' "$CALLS"
}

@test "change_ref never appears in a commit" {
  run ops_run "$REPO_ROOT/scripts/rearm.sh"
  [ "$status" -eq 0 ]
  ref="$(sed -n 's/^change_ref: //p' <<<"$output")"
  [[ "$ref" =~ ^CHG-[A-Z2-7]{6}$ ]]
  run "$REAL_GIT" --git-dir="$ORIGIN" log -p --all
  [[ "$output" != *"$ref"* ]]
  run "$REAL_GIT" -C "$OP" log -p --all
  [[ "$output" != *"$ref"* ]]
  ! grep -rq "$ref" "$OP" --include='*.yaml'
}

@test "fix changes exactly two values" {
  arm_origin
  run ops_run "$REPO_ROOT/scripts/fix.sh"
  [ "$status" -eq 0 ]
  run "$REAL_GIT" --git-dir="$ORIGIN" show --stat --format=%s refs/heads/build/demo
  [[ "${lines[0]}" == "fix(checkout): restore upstream timeout and roll config" ]]
  [[ "$output" == *"2 files changed, 2 insertions(+), 2 deletions(-)"* ]]
  [ "$(cfg_value)" = "2000" ]
  [ "$(cv_value)" = "8" ]
  [ "$(commit_files refs/heads/build/demo)" = "$CFG $ROLL " ]
}

@test "fix refuses when the timeout is already healthy" {
  tip="$(origin_tip)"
  run ops_run "$REPO_ROOT/scripts/fix.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to fix"* ]]
  [ "$(origin_tip)" = "$tip" ]
}

@test "bump uses next tag" {
  run ops_run "$REPO_ROOT/scripts/git-ops.sh" bump
  [ "$status" -eq 0 ]
  [ "$(tag_value)" = "v1.4.2" ]
  [ "$(commit_files refs/heads/build/demo)" = "$KUST " ]
  [ "$(events)" = "ENSURE PUSH ANNOTATE REV " ]   # the image is loaded before the push
  run ops_run "$REPO_ROOT/scripts/git-ops.sh" bump
  [ "$(tag_value)" = "v1.4.3" ]
  [ "$(cfg_value)" = "2000" ]
  [ "$(cv_value)" = "7" ]
}

@test "naive-revert refuses when HEAD is not an image bump" {
  tip="$(origin_tip)"
  run ops_run "$REPO_ROOT/scripts/naive-revert.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HEAD is not an image bump"* ]]
  [ "$(origin_tip)" = "$tip" ]
  # a config commit is not an image bump either
  arm_origin
  run ops_run "$REPO_ROOT/scripts/naive-revert.sh"
  [ "$status" -ne 0 ]
}

@test "naive-revert reverts, waits green, then bumps and waits degraded" {
  ops_run "$REPO_ROOT/scripts/rearm.sh" >/dev/null     # armed, HEAD is the image bump v1.4.2
  : > "$CALLS"
  run ops_run "$REPO_ROOT/scripts/naive-revert.sh"
  [ "$status" -eq 0 ]
  # revert push, refresh, synced, Healthy; then the unrelated deploy, refresh, synced, Degraded
  [ "$(events)" = "PUSH ANNOTATE REV HEALTH ENSURE PUSH ANNOTATE REV HEALTH " ]
  [[ "$output" == *"green: image back to v1.4.1"*"security fix is gone"*"aborted again: still armed"* ]]
  run origin_log
  [[ "${lines[0]}" == "chore(checkout): bump image to v1.4.2" ]]
  [[ "${lines[1]}" == Revert* ]]
  [ "$(cfg_value)" = "200" ]
}

@test "naive-revert stops at green with NAIVE_STOP_AT_GREEN=1" {
  ops_run "$REPO_ROOT/scripts/rearm.sh" >/dev/null
  : > "$CALLS"
  export NAIVE_STOP_AT_GREEN=1
  run ops_run "$REPO_ROOT/scripts/naive-revert.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"security fix is gone"* ]]
  [[ "$output" != *"aborted again"* ]]
  [ "$(events)" = "PUSH ANNOTATE REV HEALTH " ]
  [ "$(tag_value)" = "v1.4.1" ]
}

@test "disarm --image v1.4.1 restores value and tag in one commit" {
  ops_run "$REPO_ROOT/scripts/rearm.sh" >/dev/null     # armed, tag v1.4.2
  before="$("$REAL_GIT" --git-dir="$ORIGIN" rev-list --count refs/heads/build/demo)"
  run ops_run "$REPO_ROOT/scripts/git-ops.sh" disarm --image v1.4.1
  [ "$status" -eq 0 ]
  [ "$("$REAL_GIT" --git-dir="$ORIGIN" rev-list --count refs/heads/build/demo)" -eq $((before + 1)) ]
  [ "$(cfg_value)" = "2000" ]
  [ "$(cv_value)" = "8" ]
  [ "$(tag_value)" = "v1.4.1" ]
  [ "$(commit_files refs/heads/build/demo)" = "$CFG $ROLL $KUST " ]
  grep -q '^HEALTH checkout' "$CALLS"
}

@test "disarm is a no-op when nothing differs" {
  tip="$(origin_tip)"
  run ops_run "$REPO_ROOT/scripts/git-ops.sh" disarm --image v1.4.1
  [ "$status" -eq 0 ]
  [ "$(origin_tip)" = "$tip" ]
  ! grep -q '^PUSH' "$CALLS"
}

@test "disarm --git-only does not wait" {
  arm_origin
  run ops_run "$REPO_ROOT/scripts/git-ops.sh" disarm --git-only
  [ "$status" -eq 0 ]
  [ "$(cfg_value)" = "2000" ]
  [ "$(events)" = "PUSH " ]               # no refresh, no revision wait, no health wait
}

@test "disarm --git-only warns and skips when there is no operator clone" {
  printf 'OPERATOR_DIR=%s\n' "$BATS_TEST_TMPDIR/not-there" > "$FIXTURE/.env"
  arm_origin
  tip="$(origin_tip)"
  run ops_run "$REPO_ROOT/scripts/git-ops.sh" disarm --git-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping"* ]]
  [ "$(origin_tip)" = "$tip" ]
}

@test "scripts refuse a foreign kube context before changing anything" {
  make_stub "$STUBS" kubectl 'case "$*" in "config current-context") echo dv-cd-lc-prd-us-east-1 ;; *) exit 1 ;; esac'
  tip="$(origin_tip)"
  run ops_run "$REPO_ROOT/scripts/rearm.sh"
  [ "$status" -eq 3 ]
  [[ "$output" == *"refusing"* ]]
  [ "$(origin_tip)" = "$tip" ]
}

@test "STAGE=1 output: every line <= STAGE_COLS and no cause: line" {
  export STAGE=1 ENSURE_IMAGE="$STUBS/ensure-image.sh"
  run_stage() {
    run --separate-stderr ops_run "$@"
    [ "$status" -eq 0 ]
    local line
    for line in "${lines[@]}" ; do
      [ "${#line}" -le "$STAGE_COLS" ] || { echo "stdout too long (${#line}): $line" >&2; return 1; }
      [[ "$line" != cause:* && "$line" != bump:* && "$line" != change_ref:* ]]
      [[ ! "$line" =~ [0-9a-f]{40} ]]
    done
    local errline
    while IFS= read -r errline; do
      [ "${#errline}" -le "$STAGE_COLS" ] || { echo "stderr too long (${#errline}): $errline" >&2; return 1; }
    done <<<"$stderr"
    [[ "$output" != *"To "* && "$output" != *"remote:"* ]]
    [[ "$output$stderr" != *present* ]]     # ensure-image's own output stays off the stage
  }
  run_stage "$REPO_ROOT/scripts/rearm.sh"
  [ "${#lines[@]}" -ge 3 ]
  run_stage "$REPO_ROOT/scripts/naive-revert.sh"
  [[ "$output" == *"green: image back to v1.4.1"* ]]
  run_stage "$REPO_ROOT/scripts/fix.sh"
  [[ "$output" == *"pushed: config 2000, cv 8"* ]]
  run_stage "$REPO_ROOT/scripts/git-ops.sh" bump
  [[ "$output" == *"pushed: image v1.4.3"* ]]
  run_stage "$REPO_ROOT/scripts/git-ops.sh" disarm --image v1.4.1
  [[ "$output" == *"pushed: image v1.4.1"* ]]
  run_stage "$REPO_ROOT/scripts/seed-history.sh"
}

@test "STAGE=1 timeouts stay short" {
  export STAGE=1 ARGO_WAIT_S=2
  echo Degraded > "$STUBS/FORCE_HEALTH"
  arm_origin
  export HEALTH_WAIT_S=2
  run --separate-stderr ops_run "$REPO_ROOT/scripts/git-ops.sh" disarm
  [ "$status" -eq 4 ]
  [ "${#stderr}" -le "$STAGE_COLS" ] || [[ "$(awk '{ if (length($0) > m) m = length($0) } END { print m }' <<<"$stderr")" -le "$STAGE_COLS" ]]
}

@test "STAGE=1 rearm writes cause, bump and change_ref to .operator/last-rearm" {
  export STAGE=1
  run --separate-stderr ops_run "$REPO_ROOT/scripts/rearm.sh"
  [ "$status" -eq 0 ]
  f="$FIXTURE/.operator/last-rearm"
  [ -f "$f" ]
  grep -qE '^cause: [0-9a-f]{40}$' "$f"
  grep -qE '^bump: [0-9a-f]{40}$' "$f"
  grep -qE '^change_ref: CHG-[A-Z2-7]{6}$' "$f"
  [ "$(sed -n 's/^bump: //p' "$f")" = "$(origin_tip)" ]
  [[ "$output" != *cause* && "$output" != *CHG-* ]]
}
