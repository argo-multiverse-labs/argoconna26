#!/usr/bin/env bats
# Recording targets: dry-run only, no cluster and no recorder needed.

setup() { REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "record-rung-N records demo-rung-N at the stage terminal size (DEMO_COLS, default 78)" {
  run env -u DEMO_COLS make -n -C "$REPO_ROOT" record-rung-1
  [[ "$output" == *"--window-size \"78x40\""* ]]
  for n in 1 2 3; do
    run env DEMO_COLS=72 make -n -C "$REPO_ROOT" "record-rung-$n"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--window-size \"72x40\""* ]]
    [[ "$output" == *"demo-rung-$n"* ]]
    [[ "$output" == *"/rung-$n-"* ]]
  done
}

@test "record targets and gif are listed by make help" {
  run make -C "$REPO_ROOT" help
  [[ "$output" == *record-rung-3* ]]
  [[ "$output" == *gif* ]]
}

@test "gif refuses when there is no cast" {
  run make -C "$REPO_ROOT" gif RECORDINGS_DIR="$BATS_TEST_TMPDIR/none"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no cast"* ]]
}
