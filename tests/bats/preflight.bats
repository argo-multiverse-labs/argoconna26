#!/usr/bin/env bats
# Tests for scripts/preflight.sh (kubectl, kind and curl are stubs; nothing touches a cluster)

load helpers

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$FIXTURE"
  mkdir -p "$FIXTURE/.kube"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  # The local kubeconfig still names the demo context, but the API server is gone
  # (for example the kind container stopped after a docker restart).
  make_stub "$STUBS" kubectl 'case "$*" in
    "config current-context") echo kind-argoconna26 ;;
    *) echo "The connection to the server 127.0.0.1:6443 was refused" >&2; exit 1 ;;
  esac'
  make_stub "$STUBS" kind 'echo argoconna26'
  make_stub "$STUBS" curl 'exit 7'
  export PATH="$STUBS:$PATH" TOOLS_BIN="$STUBS"
}

@test "preflight reports an unreachable API server and still prints the summary" {
  run bash -c "cd '$FIXTURE' && '$REPO_ROOT/scripts/preflight.sh'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"API server unreachable"* ]]
  [[ "$output" == *"--- pods ---"* ]]
  [[ "$output" == *"--- endpoints ---"* ]]
  [[ "$output" == *"Result: "* ]]
}

# section SECTION : run one preflight section in the fixture; prints its lines and FAIL=<n> WARN=<n>.
section() {
  bash -c "cd '$FIXTURE' && . '$REPO_ROOT/scripts/preflight.sh' && load_env && section_$1; echo FAIL=\$FAIL WARN=\$WARN"
}

@test "bridge_hooks fails while bridge-env exists, naming the keys and never the values" {
  make_stub "$STUBS" kubectl 'case "$*" in
    "config current-context") echo kind-argoconna26 ;;
    *"get --raw=/readyz"*) echo ok ;;
    *"get secret bridge-env"*) echo "{\"data\":{\"TEST_CONFIDENCE_THRESHOLD\":\"MS4wMQ==\"}}" ;;
    *) exit 1 ;;
  esac'
  make_stub "$STUBS" curl 'echo "{\"test_hooks_active\": true, \"confidence_threshold\": 1.01, \"holmes_timeout_s\": 115}"'
  run section bridge_hooks
  [[ "$output" == *"[FAIL]"*"bridge-env"*"TEST_CONFIDENCE_THRESHOLD"* ]]
  [[ "$output" == *"[FAIL]"*"test hooks active"*"1.01"* ]]
  [[ "$output" != *"MS4wMQ"* ]]
  [[ "$output" == *"FAIL=2 "* ]]
}

@test "bridge_hooks fails on a stale CONFIDENCE_THRESHOLD key too (any key in bridge-env)" {
  make_stub "$STUBS" kubectl 'case "$*" in
    "config current-context") echo kind-argoconna26 ;;
    *"get --raw=/readyz"*) echo ok ;;
    *"get secret bridge-env"*) echo "{\"data\":{\"CONFIDENCE_THRESHOLD\":\"MS4wMQ==\"}}" ;;
    *) exit 1 ;;
  esac'
  make_stub "$STUBS" curl 'echo "{\"test_hooks_active\": false, \"confidence_threshold\": 0.7, \"holmes_timeout_s\": 115}"'
  run section bridge_hooks
  [[ "$output" == *"[FAIL]"*"CONFIDENCE_THRESHOLD"* ]]
  [[ "$output" == *"FAIL=1 "* ]]
}

@test "bridge_hooks passes with no bridge-env and a clean /status" {
  make_stub "$STUBS" kubectl 'case "$*" in
    "config current-context") echo kind-argoconna26 ;;
    *"get --raw=/readyz"*) echo ok ;;
    *"get secret bridge-env"*) ;;
    *) exit 1 ;;
  esac'
  make_stub "$STUBS" curl 'echo "{\"test_hooks_active\": false, \"confidence_threshold\": 0.7, \"holmes_timeout_s\": 115}"'
  run section bridge_hooks
  [[ "$output" == *"[PASS]"*"no bridge-env"* ]]
  [[ "$output" == *"[PASS]"*"no test hook active"* ]]
  [[ "$output" == *"FAIL=0 WARN=0"* ]]
}

@test "bridge-hooks.sh check exits 1 while bridge-env exists and 0 without it" {
  make_stub "$STUBS" kubectl 'case "$*" in
    "config current-context") echo kind-argoconna26 ;;
    *"get secret bridge-env"*) if [ -f "$BATS_TEST_TMPDIR/has-env" ]; then echo "{\"data\":{\"TEST_HOLMES_TIMEOUT_S\":\"MQ==\"}}"; fi ;;
    *) exit 1 ;;
  esac'
  touch "$BATS_TEST_TMPDIR/has-env"
  run bash -c "cd '$FIXTURE' && BATS_TEST_TMPDIR='$BATS_TEST_TMPDIR' '$REPO_ROOT/scripts/bridge-hooks.sh' check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TEST_HOLMES_TIMEOUT_S"* ]]
  [[ "$output" != *"MQ=="* ]]
  rm "$BATS_TEST_TMPDIR/has-env"
  run bash -c "cd '$FIXTURE' && BATS_TEST_TMPDIR='$BATS_TEST_TMPDIR' '$REPO_ROOT/scripts/bridge-hooks.sh' check"
  [ "$status" -eq 0 ]
}
