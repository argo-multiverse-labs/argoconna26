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
