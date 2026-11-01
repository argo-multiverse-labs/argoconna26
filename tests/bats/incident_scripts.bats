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
  export STAGE=1 STAGE_STRICT=1 ENSURE_IMAGE="$STUBS/ensure-image.sh"
  run_stage() {
    local want=0
    if [[ "$1" == --status ]]; then want="$2"; shift 2; fi
    run --separate-stderr ops_run "$@"
    [ "$status" -eq "$want" ]
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
  # the refusals have short stage forms too
  run_stage --status 7 "$REPO_ROOT/scripts/rearm.sh"
  [ "$stderr" = "refused: already armed" ]
  run_stage "$REPO_ROOT/scripts/fix.sh"
  [[ "$output" == *"pushed: config 2000, cv 8"* ]]
  run_stage --status 1 "$REPO_ROOT/scripts/naive-revert.sh"
  [ "$stderr" = "refused: not an image bump" ]
  run_stage --status 1 "$REPO_ROOT/scripts/fix.sh"
  [ "$stderr" = "refused: already fixed" ]
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

@test "seed waits for Healthy even when the tip is already disarmed" {
  # An earlier disarm or fix pushed its commit but never saw the rollout finish.
  echo Degraded > "$STUBS/FORCE_HEALTH"
  export HEALTH_WAIT_S=2
  tip="$(origin_tip)"
  run ops_run "$REPO_ROOT/scripts/seed-history.sh"
  [ "$status" -eq 4 ]
  [ "$(origin_tip)" = "$tip" ]
  [[ "$(origin_log)" != *"PR-242"* ]]
}

@test "seed refuses while a Ready pod still reads the armed value on a disarmed tip" {
  echo 200 > "$STUBS/FORCE_GAUGE"
  tip="$(origin_tip)"
  run ops_run "$REPO_ROOT/scripts/seed-history.sh"
  [ "$status" -eq 4 ]
  [[ "$output" == *"reports UPSTREAM_TIMEOUT_MS=200"* ]]
  [ "$(origin_tip)" = "$tip" ]
}

@test "disarm on a disarmed tip checks health and the fleet, and pushes nothing" {
  run ops_run "$REPO_ROOT/scripts/git-ops.sh" disarm
  [ "$status" -eq 0 ]
  grep -q '^HEALTH checkout' "$CALLS"
  grep -q '^FLEET' "$CALLS"
  ! grep -q '^PUSH' "$CALLS"
}

@test "STAGE=1 fix, disarm and naive-revert leave .operator/last-run alone" {
  export STAGE=1
  mkdir -p "$FIXTURE/.operator"
  printf 'RUN_TS=20261101T000000Z\nRUN_MONO=123\n' > "$FIXTURE/.operator/last-run"
  cp "$FIXTURE/.operator/last-run" "$BATS_TEST_TMPDIR/last-run.orig"
  ops_run "$REPO_ROOT/scripts/rearm.sh" >/dev/null 2>&1
  ops_run "$REPO_ROOT/scripts/naive-revert.sh" >/dev/null 2>&1
  ops_run "$REPO_ROOT/scripts/fix.sh" >/dev/null 2>&1
  ops_run "$REPO_ROOT/scripts/git-ops.sh" disarm --image v1.4.1 >/dev/null 2>&1
  cmp "$FIXTURE/.operator/last-run" "$BATS_TEST_TMPDIR/last-run.orig"
  grep -qE '^revert: [0-9a-f]{40}$' "$FIXTURE/.operator/last-revert"
  grep -qE '^fix: [0-9a-f]{40}$' "$FIXTURE/.operator/last-fix"
  grep -qE '^disarm: [0-9a-f]{40}$' "$FIXTURE/.operator/last-disarm"
}

@test "STAGE=1 seed writes cause and change_ref to .operator/last-rearm" {
  export STAGE=1
  run --separate-stderr ops_run "$REPO_ROOT/scripts/seed-history.sh"
  [ "$status" -eq 0 ]
  f="$FIXTURE/.operator/last-rearm"
  grep -qE '^cause: [0-9a-f]{40}$' "$f"
  grep -qE '^change_ref: CHG-[A-Z2-7]{6}$' "$f"
  "$REAL_GIT" --git-dir="$ORIGIN" log -1 --format=%s "$(sed -n 's/^cause: //p' "$f")" | grep -q '^PR-242'
}

@test "naive-revert refuses when HEAD is its own revert" {
  ops_run "$REPO_ROOT/scripts/rearm.sh" >/dev/null
  NAIVE_STOP_AT_GREEN=1 ops_run "$REPO_ROOT/scripts/naive-revert.sh" >/dev/null
  tip="$(origin_tip)"
  run ops_run "$REPO_ROOT/scripts/naive-revert.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HEAD is not an image bump"* ]]
  [ "$(origin_tip)" = "$tip" ]
}

@test "naive-revert refuses when HEAD is a disarm that only pins the image" {
  ops_run "$REPO_ROOT/scripts/git-ops.sh" bump >/dev/null
  ops_run "$REPO_ROOT/scripts/git-ops.sh" disarm --image v1.4.1 >/dev/null
  [ "$(commit_files refs/heads/build/demo)" = "$KUST " ]
  tip="$(origin_tip)"
  run ops_run "$REPO_ROOT/scripts/naive-revert.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HEAD is not an image bump"* ]]
  [ "$(origin_tip)" = "$tip" ]
}

@test "naive-revert refuses when the revert would land on a tag that has the CVE fix" {
  arm_origin
  ops_run "$REPO_ROOT/scripts/git-ops.sh" bump >/dev/null     # v1.4.2, the CVE release
  ops_run "$REPO_ROOT/scripts/git-ops.sh" bump >/dev/null     # v1.4.3
  tip="$(origin_tip)"
  run ops_run "$REPO_ROOT/scripts/naive-revert.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lands on v1.4.2, which already has the CVE fix"* ]]
  [[ "$output" != *"security fix is gone"* ]]
  [ "$(origin_tip)" = "$tip" ]
}

@test "naive-revert's revert commit goes through the pre-commit hook" {
  ops_run "$REPO_ROOT/scripts/rearm.sh" >/dev/null
  printf '#!/bin/sh\necho HOOK >> "%s"\n' "$CALLS" > "$OP/.git/hooks/pre-commit"
  : > "$CALLS"
  export NAIVE_STOP_AT_GREEN=1
  run ops_run "$REPO_ROOT/scripts/naive-revert.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -E '^(HOOK|PUSH)$' "$CALLS" | head -2 | tr '\n' ' ')" = "HOOK PUSH " ]
  "$REAL_GIT" --git-dir="$ORIGIN" log -1 --format=%B refs/heads/build/demo | grep -q '^This reverts commit [0-9a-f]\{40\}\.$'
}

@test "STAGE_STRICT=1 makes an over-long beat fail instead of being cut" {
  run --separate-stderr in_ops "STAGE=1 STAGE_STRICT=1 beat '$(printf 'x%.0s' $(seq 1 $((STAGE_COLS + 1))))'; echo after"
  [ "$status" -ne 0 ]
  [[ "$output" != *after* ]]
  run --separate-stderr in_ops "STAGE=1 beat '$(printf 'x%.0s' $(seq 1 $((STAGE_COLS + 1))))'"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq "$STAGE_COLS" ]
}
