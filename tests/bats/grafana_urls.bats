#!/usr/bin/env bats
# Tests for scripts/grafana-run-url.sh

load helpers

setup() {
  WIN="$BATS_TEST_TMPDIR/window"
}

@test "kiosk URL: the trust-ladder dashboard, kiosk flags, refresh 5s and the last 30 minutes" {
  run "$REPO_ROOT/scripts/grafana-run-url.sh" --kiosk
  [ "$status" -eq 0 ]
  [ "$output" = "http://127.0.0.1:30030/d/trust-ladder/trust-ladder?orgId=1&kiosk&_dash.hideTimePicker&_dash.hideVariables&_dash.hideLinks&refresh=5s&from=now-30m&to=now" ]
}

@test "run URL: an absolute range from 5 minutes before SINCE to 5 minutes after UNTIL, in epoch ms, no refresh" {
  printf 'SINCE=1793547000\nUNTIL=1793547600\nPR=12\n' > "$WIN"
  run "$REPO_ROOT/scripts/grafana-run-url.sh" "$WIN"
  [ "$status" -eq 0 ]
  [[ "$output" == "http://127.0.0.1:30030/d/trust-ladder/trust-ladder?orgId=1&kiosk&_dash.hideTimePicker&_dash.hideVariables&_dash.hideLinks&from=1793546700000&to=1793547900000" ]]
  [[ "$output" != *refresh* ]]
}

@test "run URL: a window file without UNTIL fails" {
  printf 'SINCE=1793547000\n' > "$WIN"
  run "$REPO_ROOT/scripts/grafana-run-url.sh" "$WIN"
  [ "$status" -ne 0 ]
}

@test "run URL: a missing file fails" {
  run "$REPO_ROOT/scripts/grafana-run-url.sh" "$BATS_TEST_TMPDIR/nope"
  [ "$status" -ne 0 ]
}

@test "run URL: a window file is data, not code" {
  printf 'SINCE=1793547000\nUNTIL=$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" > "$WIN"
  run "$REPO_ROOT/scripts/grafana-run-url.sh" "$WIN"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}
