#!/usr/bin/env bats
# Tests for tests/e2e/rung3.sh's promotion step, with promotion-pr.sh, gh and preflight as stubs.
# Nothing touches a cluster, GitHub or systemd.
#
# preflight 3 --pre-promotion needs exactly one open act promotion PR (scripts/preflight.sh,
# _runtime_promotion_state), as on stage (stage-day.sh arm-rung-3: reset-rung-3 opens it, then
# the preflight, then the merge). So rung3.sh opens the act PR first, runs the preflight, then
# merges that same PR, and does not rely on an act PR some earlier command left open.

load helpers

setup() {
  T="$(mktemp -d)"
  CALLS="$T/calls"
  mkdir -p "$T/root/scripts"
  cat >"$T/root/scripts/preflight.sh" <<EOF
#!/usr/bin/env bash
echo "preflight \$*" >>"$CALLS"
exit "\${PREFLIGHT_RC:-0}"
EOF
  chmod +x "$T/root/scripts/preflight.sh"
  cat >"$T/drive.sh" <<EOF
#!/usr/bin/env bash
# Source rung3.sh without running main, stub its collaborators, run the promotion step.
. "$REPO_ROOT/tests/e2e/rung3.sh"
set +e
ROOT="$T/root" RUN_LOG="$T/run.log" REPO_SLUG=org/repo AUTONOMY_FILE=aiops/autonomy.yaml TRACKED_BRANCH=build/demo
run_promo() {
  echo "promo \$*" >>"$CALLS"
  if [[ "\$1" == ensure ]]; then printf 'promotion PR open\npr: 7\nbranch: promote/%s-20261103T000000Z-abcd\n' "\$2"; fi
}
gh() { [[ "\$1 \$2" == "pr diff" ]] && echo "\$AUTONOMY_FILE"; return 0; }
pr_state_is() { echo "state \$1 \$2" >>"$CALLS"; [[ "\$2" == MERGED ]] && grep -q '^promo merge' "$CALLS"; }
delete_remote_branch() { echo "delete \$1" >>"$CALLS"; }
wait_for() { return 0; }
set -e
promote_to_act_after_preflight
echo "PROMO_PR=\$PROMO_PR PROMO_BRANCH=\$PROMO_BRANCH"
EOF
  chmod +x "$T/drive.sh"
}

teardown() { rm -rf "$T"; }

@test "rung3 opens the act promotion PR, runs preflight 3 --pre-promotion, then merges that PR" {
  run bash "$T/drive.sh"
  [ "$status" -eq 0 ]
  run grep -E '^(promo|preflight)' "$CALLS"
  [ "${lines[0]}" = "promo ensure act" ]
  [ "${lines[1]}" = "preflight 3 --pre-promotion" ]
  [ "${lines[2]}" = "promo merge 7 --admin" ]
  [ "${lines[3]}" = "promo record-approval 7" ]
  [ "$(grep -c '^promo ensure' "$CALLS")" -eq 1 ]
}

@test "rung3 stops before the merge when preflight 3 --pre-promotion fails, with the open PR recorded for cleanup" {
  export PREFLIGHT_RC=1
  run bash "$T/drive.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"preflight 3 --pre-promotion failed"* ]]
  ! grep -q '^promo merge' "$CALLS"
  grep -q '^promo ensure act' "$CALLS"
}

@test "rung3.sh runs main only when executed, not when sourced" {
  run bash -c ". '$REPO_ROOT/tests/e2e/rung3.sh'; declare -F promote_to_act_after_preflight >/dev/null && echo sourced-ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *sourced-ok* ]]
}
