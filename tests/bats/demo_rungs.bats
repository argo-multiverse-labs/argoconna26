#!/usr/bin/env bats
# Tests for scripts/demo-common.sh and scripts/demo-rung-{1,2,3}.sh (Task 6.4).
# make, kubectl, gh, curl, journalctl, promotion-pr.sh and the browser are stubs over a scripted
# world (tests/bats/demo_helpers.bash). Nothing touches a cluster, GitHub or systemd.

load helpers
load demo_helpers

# A passing run of each rung, for the output checks.
happy_rung1() { demo_setup suggest; seed_rung1; set_comment "$(rca_body)"; }
happy_rung2() { demo_setup suggest; set_prs "$(fix_body propose)"; echo 12 >/dev/null; export DEMO_AUTOMERGE_FOR_TEST=1; }
happy_rung3() {
  demo_setup act
  set_prs "$(fix_body act)"
  echo "$BOT" >"$ST/auto-merge-by"
}

@test "demo-magic is vendored at DEMO_MAGIC_SHA with its provenance line" {
  sha="$(sed -n 's/^DEMO_MAGIC_SHA=//p' "$REPO_ROOT/versions.env")"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
  grep -q "paxtonhare/demo-magic at DEMO_MAGIC_SHA ($sha" "$REPO_ROOT/scripts/demo-magic.sh"
  grep -q 'Copyright (c) 2015-2022 Paxton Hare' "$REPO_ROOT/scripts/demo-magic.sh"
}

@test "automerge helper ignored unless NO_WAIT=true" {
  happy_rung2
  export NO_WAIT=false FIX_PR_WAIT_S=3
  cd "$FIXTURE"
  run bash -c "yes '' | '$REPO_ROOT/scripts/demo-rung-2.sh'"
  [ "$status" -eq 4 ]
  ! grep -q '^gh pr merge' "$LOG"
  # and rung 3 never starts it, even with NO_WAIT=true and the variable set
  happy_rung3
  export DEMO_AUTOMERGE_FOR_TEST=1
  run rung 3
  [ "$status" -eq 0 ]
  ! grep -q '^gh pr merge' "$LOG"
}

@test "every printed line and prompt+command fits STAGE_COLS" {
  happy_rung1
  run rung 1
  [ "$status" -eq 0 ]
  assert_fits "$output"
  happy_rung2
  run rung 2
  [ "$status" -eq 0 ]
  assert_fits "$output"
  happy_rung3
  run rung 3
  [ "$status" -eq 0 ]
  assert_fits "$output"
  [[ "$(strip_ansi "$output")" == *"[PE]\$ make night"* ]]
}

@test "a typed command that does not fit is refused" {
  happy_rung1
  run bash -c "cd '$FIXTURE' && . '$REPO_ROOT/scripts/demo-common.sh' && typed 'make $(printf 'x%.0s' $(seq "$STAGE_COLS"))'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"typed line too long"* ]]
}

@test "no cause: line or 40-hex SHA reaches stdout" {
  for n in 1 2 3; do
    "happy_rung$n"
    run rung "$n"
    [ "$status" -eq 0 ]
    ! grep -q 'cause:' <<<"$output"
    ! grep -qE '[0-9a-f]{40}' <<<"$output"
  done
}

@test "rung 1 happy path: bump, RCA, fix, resolved, assertions" {
  happy_rung1
  run rung 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"RCA: comment posted"* ]]
  [[ "$output" == *"incident resolved"* ]]
  [[ "$output" == *"PASS: RCA names the cause"* ]]
  grep -q '^make bump' "$LOG"
  grep -q '^make fix' "$LOG"
  grep -q '^open https://github.com/x/y/commit' "$LOG"
}

@test "typed make commands never print make's directory lines (run under make demo-rung-N)" {
  happy_rung1
  run rung 1
  [ "$status" -eq 0 ]
  grep -qx 'make bump --no-print-directory' "$LOG"
  grep -qx 'make fix --no-print-directory' "$LOG"
  [[ "$output" != *"[PE]$ make bump --no-print-directory"* ]] # the screen shows the plain command
}

@test "under NO_WAIT=true, rung 1 fails when the bot comment is a refusal" {
  happy_rung1
  set_comment "$(refusal_body)"
  run rung 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"refused: low_confidence"* ]]
}

@test "under NO_WAIT=true, rung 1 fails when the RCA names a different cause" {
  happy_rung1
  set_comment "$(rca_body | sed "s/$CAUSE/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee/g")"
  run rung 1
  [ "$status" -ne 0 ]
}

@test "on stage, a refusal prints refused: <reason>, opens the comment and runs the human fix" {
  happy_rung1
  set_comment "$(refusal_body)"
  export NO_WAIT=false
  cd "$FIXTURE"
  run bash -c "yes '' | '$REPO_ROOT/scripts/demo-rung-1.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refused: low_confidence"* ]]
  grep -q '^open https://github.com/x/y/commit' "$LOG"
  grep -q '^make fix' "$LOG"
  [[ "$output" == *"healthy"* ]]
}

@test "on stage, a handoff prints handoff: cut to clip and exits 0" {
  happy_rung1
  set_comment "$(handoff_body)"
  export NO_WAIT=false
  cd "$FIXTURE"
  run bash -c "yes '' | '$REPO_ROOT/scripts/demo-rung-1.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"handoff: cut to clip"* ]]
  ! grep -q '^make fix' "$LOG"
}

@test "on stage, a PII block prints blocked: pii and runs the human fix" {
  happy_rung1
  set_comment "$(printf '## Agent output blocked\n\nThe answer had something that looks like personal data.\n\nA human should take this one.\n')"
  export NO_WAIT=false
  cd "$FIXTURE"
  run bash -c "yes '' | '$REPO_ROOT/scripts/demo-rung-1.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"blocked: pii"* ]]
  grep -q '^make fix' "$LOG"
}

@test "rung 1 refuses when no cause was seeded" {
  demo_setup suggest
  run rung 1
  [ "$status" -ne 0 ]
  ! grep -q '^make bump' "$LOG"
}

@test "rung 2 happy path: promotion, rearm, fix PR, merge, assertions" {
  happy_rung2
  run rung 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"promotion PR: clean"* ]]
  [[ "$output" == *"recorded: admin bypass"* ]]
  [[ "$output" == *"bot PR #7"* ]]
  [[ "$output" == *"PASS: fix PR cites the cause"* ]]
  grep -q '^promo record-approval 12' "$LOG"
  grep -q '^make rearm' "$LOG"
}

@test "rung 2 refreshes the Application after the merge" {
  happy_rung2
  run rung 2
  [ "$status" -eq 0 ]
  m="$(grep -n '^gh pr merge 7' "$LOG" | head -1 | cut -d: -f1)"
  a="$(grep -n '^kubectl annotate' "$LOG" | head -1 | cut -d: -f1)"
  [ -n "$m" ] && [ -n "$a" ]
  [ "$m" -lt "$a" ]
  grep -q 'argocd.argoproj.io/refresh=normal' "$LOG"
}

@test "rung 2 stops when promotion-pr.sh verify fails" {
  happy_rung2
  export VERIFY_RC=8
  run rung 2
  [ "$status" -eq 8 ]
  [[ "$output" == *"refused: promotion PR changed"* ]]
  ! grep -q '^make rearm' "$LOG"
  ! grep -q '^promo record-approval' "$LOG"
}

@test "reject branch demotes, waits on the autonomy file, then fixes" {
  happy_rung2
  unset DEMO_AUTOMERGE_FOR_TEST
  export DEMO_REJECT_FOR_TEST=1
  run rung 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"rejected: demoting"* ]]
  [[ "$output" == *"autonomy: suggest"* ]]
  d="$(grep -n '^make demote' "$LOG" | head -1 | cut -d: -f1)"
  f="$(grep -n '^make fix' "$LOG" | head -1 | cut -d: -f1)"
  a="$(grep -n 'contents/aiops/autonomy.yaml' "$LOG" | awk -F: -v d="$d" '$1 > d {print $1; exit}')"
  [ -n "$d" ] && [ -n "$f" ] && [ -n "$a" ]
  [ "$d" -lt "$a" ]
  [ "$a" -lt "$f" ]
  [ "$(grep -c '^make rearm' "$LOG")" -eq 1 ] # no new incident
}

@test "rung 2 shows a refusal instead of a fix PR as a feature" {
  happy_rung2
  unset DEMO_AUTOMERGE_FOR_TEST
  rm "$ST/prs.json"
  set_comment "$(refusal_body)"
  export NO_WAIT=false
  cd "$FIXTURE"
  run bash -c "yes '' | '$REPO_ROOT/scripts/demo-rung-2.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refused: low_confidence"* ]]
  grep -q '^make fix' "$LOG"
}

@test "rung 3 triggers make night outside the lock and prints the scheduled-job line" {
  happy_rung3
  run rung 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"running the nightly job now"* ]]
  [[ "$output" != *"03:00"* ]]
  grep -q '^night: lock free, held=none' "$LOG"
  ! grep -q '^make \(rearm\|bump\|fix\)' "$LOG"
  ! grep -q '^kubectl annotate' "$LOG" # no Argo nudge on stage (O13, O29)
  grep -q '^overnight-verify SINCE=[0-9]* UNTIL=[0-9]*' "$LOG"
}

@test "rung 3 opens the PR and its checks, and not the Argo CD or Grafana tabs" {
  happy_rung3
  run rung 3
  [ "$status" -eq 0 ]
  mapfile -t tabs < <(grep '^open ' "$LOG")
  [ "${#tabs[@]}" -eq 2 ]
  [ "${tabs[0]}" = "open https://github.com/x/y/pull/7" ]
  [ "${tabs[1]}" = "open https://github.com/x/y/pull/7/checks" ]
}

@test "rung 3 on a policy failure prints policy: left for review and exits 0" {
  happy_rung3
  export NO_WAIT=false
  echo '{"check_runs":[{"app":{"id":15368},"started_at":"2999-01-01T00:00:00Z","conclusion":"failure"}]}' >"$ST/checkruns.json"
  cd "$FIXTURE"
  run bash -c "yes '' | '$REPO_ROOT/scripts/demo-rung-3.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"policy: left for review"* ]]
  grep -q '^open https://github.com/x/y/pull/7/checks' "$LOG"
  ! grep -q '^gh pr merge' "$LOG"
}

@test "under NO_WAIT=true, rung 3 fails when policy-check fails" {
  happy_rung3
  echo '{"check_runs":[{"app":{"id":15368},"started_at":"2999-01-01T00:00:00Z","conclusion":"failure"}]}' >"$ST/checkruns.json"
  run rung 3
  [ "$status" -ne 0 ]
  [[ "$output" == *"policy: left for review"* ]]
  [[ "$output" == *"FAIL: policy failure"* ]]
  ! grep -q '^gh pr merge' "$LOG"
}

@test "rung 3 fails when a person merged the fix PR" {
  happy_rung3
  echo luke >"$ST/auto-merge-by"
  run rung 3
  [ "$status" -ne 0 ]
  [[ "$output" == *"merged by a person"* ]]
}

@test "rung 3 refuses when autonomy is not act" {
  happy_rung3
  echo propose >"$ST/level"
  run rung 3
  [ "$status" -eq 6 ]
  ! grep -q '^make night' "$LOG"
}

@test "the scripts take no arguments and refuse a bad NO_WAIT" {
  happy_rung1
  run bash -c "cd '$FIXTURE' && '$REPO_ROOT/scripts/demo-rung-1.sh' --help"
  [ "$status" -eq 2 ]
  NO_WAIT=maybe run rung 1
  [ "$status" -ne 0 ]
}

@test "make demo-rung-N run the scripts" {
  for n in 1 2 3; do
    run make -n --no-print-directory -C "$REPO_ROOT" "demo-rung-$n"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scripts/demo-rung-$n.sh" ]]
  done
}
