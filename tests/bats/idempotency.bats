#!/usr/bin/env bats
# scripts/idempotency.sh compare must be able to fail

load helpers

@test "compare passes on identical snapshots" {
  printf 'Pod demo/a uid=1 restarts=0\nSecret demo/s uid=2\n' > "$BATS_TEST_TMPDIR/a"
  cp "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  run "$REPO_ROOT/scripts/idempotency.sh" compare "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -eq 0 ]
  [[ "$output" == *identical* ]]
}

@test "compare fails when a UID changed" {
  printf 'Secret demo/s uid=2\n' > "$BATS_TEST_TMPDIR/a"
  printf 'Secret demo/s uid=3\n' > "$BATS_TEST_TMPDIR/b"
  run "$REPO_ROOT/scripts/idempotency.sh" compare "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -ne 0 ]
  [[ "$output" == *"uid=3"* ]]
}

@test "compare fails when a restart count changed" {
  printf 'Pod demo/a uid=1 restarts=0\n' > "$BATS_TEST_TMPDIR/a"
  printf 'Pod demo/a uid=1 restarts=1\n' > "$BATS_TEST_TMPDIR/b"
  run "$REPO_ROOT/scripts/idempotency.sh" compare "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -ne 0 ]
}

@test "compare refuses an empty snapshot" {
  : > "$BATS_TEST_TMPDIR/a"; : > "$BATS_TEST_TMPDIR/b"
  run "$REPO_ROOT/scripts/idempotency.sh" compare "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -ne 0 ]
}
