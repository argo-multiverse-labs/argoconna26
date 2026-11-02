#!/usr/bin/env bats
# Tests for scripts/stage-day.sh. make, gh, preflight, promotion-pr.sh and litellm.sh are stubs;
# nothing touches the cluster or GitHub.

load helpers

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$FIXTURE"
  mkdir -p "$FIXTURE/.operator"
  export LOG="$BATS_TEST_TMPDIR/calls.log"
  : >"$LOG"
  export EVIDENCE_DIR="$BATS_TEST_TMPDIR/evidence"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  make_stub "$STUBS" make 'echo "make ${*: -1}" >>"$LOG"; [[ "${FAIL_MAKE:-}" == "${*: -1}" ]] && exit 2
    # BELOW_PROPOSE=1: the first reset-rung-3 finds autonomy at suggest and exits 6 (Task 6.3)
    if [[ "${BELOW_PROPOSE:-}" == 1 && "${*: -1}" == reset-rung-3 && ! -e "$LOG.r3" ]]; then : >"$LOG.r3"; exit 6; fi
    exit 0'
  make_stub "$STUBS" gh 'echo "gh $*" >>"$LOG"; [[ -z "${GH_AUTH_FAIL:-}" ]]'
  make_stub "$STUBS" preflight 'echo "preflight $*${PREFLIGHT_REQUIRE_SCORE:+ (score required)}" >>"$LOG"; [[ "$*" != "${FAIL_PREFLIGHT:-none}" ]]'
  make_stub "$STUBS" promotion 'echo "promotion $*" >>"$LOG"; [[ "$1" != "${FAIL_PROMOTION:-none}" ]]'
  make_stub "$STUBS" litellm 'echo "${SPEND:-live 1.0000 remaining 40.0000 cumulative 12.0000 budget 50.00}"'
  make_stub "$STUBS" grafana 'echo "http://kiosk.example/"'
  export PATH="$STUBS:$PATH" TOOLS_BIN="$STUBS"
  export STAGE_DAY_PREFLIGHT="$STUBS/preflight" STAGE_DAY_PROMOTION="$STUBS/promotion" \
    STAGE_DAY_LITELLM="$STUBS/litellm" STAGE_DAY_GRAFANA_URL="$STUBS/grafana"
  printf 'pr=77\nhead=abc\nbranch=promote/act-x\n' >"$FIXTURE/.operator/promotion-act"
  printf 'pr=76\nhead=def\nbranch=promote/propose-x\n' >"$FIXTURE/.operator/promotion-propose"
}

sd() { (cd "$FIXTURE" && "$REPO_ROOT/scripts/stage-day.sh" "$@"); }

@test "morning runs the steps in order" {
  run sd morning
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG")" = "make reset-demo
preflight 1 (score required)
gh auth status
make job-install
preflight 3" ]
  [[ "$output" == *"morning done"* ]]
  [[ "$output" == *"http://kiosk.example/"* ]]
}

@test "morning saves the timings under the evidence dir" {
  run sd morning
  [ "$status" -eq 0 ]
  f="$(ls "$EVIDENCE_DIR"/stage-day/morning-*.txt)"
  grep -q 'ok      make reset-demo' "$f"
  grep -q 'morning done' "$f"
}

@test "morning stops at a failed reset and runs nothing after it" {
  FAIL_MAKE=reset-demo run sd morning
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED  make reset-demo"* ]]
  [ "$(cat "$LOG")" = "make reset-demo" ]
}

@test "morning fails on preflight 1 and names it" {
  FAIL_PREFLIGHT="1" run sd morning
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED  preflight 1"* ]]
  ! grep -q 'gh auth' "$LOG"
}

@test "morning fails when the LLM budget left is under the minimum" {
  SPEND="live 49.0000 remaining 1.0000 cumulative 49.0000 budget 50.00" run sd morning
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED  LLM budget"* ]]
  [[ "$output" == *"need at least"* ]]
  ! grep -q 'gh auth' "$LOG"
}

@test "morning fails when the cumulative spend reached the budget" {
  SPEND="live 1.0000 remaining 40.0000 cumulative 50.0000 budget 50.00" run sd morning
  [ "$status" -eq 1 ]
  [[ "$output" == *"at the budget"* ]]
}

@test "morning fails on an unreadable spend line" {
  SPEND="nonsense" run sd morning
  [ "$status" -eq 1 ]
  [[ "$output" == *"unreadable spend line"* ]]
}

@test "morning fails when gh is not logged in" {
  GH_AUTH_FAIL=1 run sd morning
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED  gh auth status"* ]]
  ! grep -q 'job-install' "$LOG"
}

@test "arm-rung-3 stops at the human step with no input and merges nothing" {
  run sd arm-rung-3 </dev/null
  [ "$status" -eq 3 ]
  [[ "$output" == *"HUMAN STEP"* ]]
  [[ "$output" == *"promotion PR 77"* ]]
  [ "$(cat "$LOG")" = "make reset-rung-3
preflight 3 --pre-promotion" ]
}

@test "arm-rung-3 stops when the person types q" {
  run bash -c "cd '$FIXTURE' && echo q | '$REPO_ROOT/scripts/stage-day.sh' arm-rung-3"
  [ "$status" -eq 3 ]
  ! grep -q '^promotion' "$LOG"
}

@test "arm-rung-3 after Enter merges, records the approval and runs preflight --armed" {
  run bash -c "cd '$FIXTURE' && echo | '$REPO_ROOT/scripts/stage-day.sh' arm-rung-3"
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG")" = "make reset-rung-3
preflight 3 --pre-promotion
promotion merge 77
promotion record-approval 77
preflight 3 --armed" ]
  [[ "$output" == *"running the nightly job now"* ]]
  [[ "$output" != *"03:00"* ]]
}

@test "arm-rung-3 --admin passes --admin to merge" {
  run bash -c "cd '$FIXTURE' && echo | '$REPO_ROOT/scripts/stage-day.sh' arm-rung-3 --admin"
  [ "$status" -eq 0 ]
  grep -qx 'promotion merge 77 --admin' "$LOG"
  [[ "$output" == *"admin bypass"* ]]
}

@test "arm-rung-3 stops before the human step when pre-promotion preflight fails" {
  FAIL_PREFLIGHT="3 --pre-promotion" run bash -c "cd '$FIXTURE' && echo | '$REPO_ROOT/scripts/stage-day.sh' arm-rung-3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED  preflight 3 --pre-promotion"* ]]
  [[ "$output" != *"HUMAN STEP"* ]]
}

@test "arm-rung-3 stops when merge is refused and does not record or arm" {
  FAIL_PROMOTION=merge run bash -c "cd '$FIXTURE' && echo | '$REPO_ROOT/scripts/stage-day.sh' arm-rung-3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED  promotion-pr.sh merge 77"* ]]
  ! grep -q 'record-approval' "$LOG"
  ! grep -q -- '--armed' "$LOG"
}

@test "arm-rung-3 fails clearly when no act promotion was recorded" {
  rm "$FIXTURE/.operator/promotion-act"
  run bash -c "cd '$FIXTURE' && echo | '$REPO_ROOT/scripts/stage-day.sh' arm-rung-3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no recorded act promotion"* ]]
  ! grep -q '^promotion' "$LOG"
}

@test "arm-rung-3 fails when the armed preflight fails" {
  FAIL_PREFLIGHT="3 --armed" run bash -c "cd '$FIXTURE' && echo | '$REPO_ROOT/scripts/stage-day.sh' arm-rung-3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED  preflight 3 --armed"* ]]
}

@test "usage: no subcommand, an unknown one and a stray argument exit 2" {
  run sd
  [ "$status" -eq 2 ]
  run sd evening
  [ "$status" -eq 2 ]
  run sd morning extra
  [ "$status" -eq 2 ]
  run sd arm-rung-3 --nope </dev/null
  [ "$status" -eq 2 ]
}

@test "arm-rung-3 from suggest (after reject + demote) merges the propose promotion first, then resets again" {
  BELOW_PROPOSE=1 run bash -c "cd '$FIXTURE' && printf '\n\n' | '$REPO_ROOT/scripts/stage-day.sh' arm-rung-3 --admin"
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG")" = "make reset-rung-3
promotion merge 76 --admin
promotion record-approval 76
make reset-rung-3
preflight 3 --pre-promotion
promotion merge 77 --admin
promotion record-approval 77
preflight 3 --armed" ]
  [[ "$output" == *"propose promotion PR 76"* ]]
}

@test "arm-rung-3 from suggest stops at the propose human step with no input and merges nothing" {
  BELOW_PROPOSE=1 run sd arm-rung-3
  [ "$status" -eq 3 ]
  ! grep -q '^promotion' "$LOG"
  [[ "$output" == *"propose promotion PR 76"* ]]
}
