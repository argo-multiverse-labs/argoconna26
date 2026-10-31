#!/usr/bin/env bats
# Tests for scripts/common.sh

load helpers

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$FIXTURE"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS" "$FIXTURE/.kube"
  # A pristine PATH that has the stubs first and the system after.
  export PATH="$STUBS:$PATH" TOOLS_BIN="$STUBS"
  export CLUSTER_CONTEXT=kind-argoconna26
  export KUBECONFIG="$FIXTURE/.kube/argoconna26.yaml"
  export KUBECONFIG_REL=.kube/argoconna26.yaml
  unset CLUSTER_LOCK_HELD
  HOLDER_PID=""
}

teardown() {
  if [[ -n "$HOLDER_PID" ]]; then
    pkill -P "$HOLDER_PID" 2>/dev/null || true
    kill "$HOLDER_PID" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------- require_context
@test "require_context fails on foreign context" {
  make_stub "$STUBS" kubectl 'echo dv-cd-lc-prd-us-east-1'
  run in_fixture 'require_context'
  [ "$status" -eq 3 ]
  [[ "$output" == *refusing* ]]
}

@test "require_context passes on kind-argoconna26" {
  make_stub "$STUBS" kubectl 'echo kind-argoconna26'
  run in_fixture 'require_context'
  [ "$status" -eq 0 ]
}

@test "require_context refuses a kubeconfig that is not the isolated one" {
  make_stub "$STUBS" kubectl 'echo kind-argoconna26'
  KUBECONFIG="$HOME/.kube/config" run in_fixture 'require_context'
  [ "$status" -eq 3 ]
  [[ "$output" == *refusing* ]]
}

@test "k refuses to run against a foreign kubeconfig" {
  make_stub "$STUBS" kubectl 'echo SHOULD-NOT-RUN'
  KUBECONFIG="$HOME/.kube/config" run in_fixture 'k get nodes'
  [ "$status" -ne 0 ]
  [[ "$output" != *SHOULD-NOT-RUN* ]]
}

@test "k always passes an explicit --context" {
  make_stub "$STUBS" kubectl 'echo "$*"'
  run in_fixture 'k get nodes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"--context kind-argoconna26 get nodes"* ]]
}

# ---------------------------------------------------------------- wait_for
@test "wait_for times out with description" {
  run in_fixture 'wait_for "never" 2 false'
  [ "$status" -eq 4 ]
  [[ "$output" == *never* ]]
}

@test "wait_for returns when condition true" {
  run in_fixture 'wait_for "ok" 2 true'
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------- git guards
@test "require_clean_tree fails on dirty tree" {
  echo dirty > "$FIXTURE/untracked.txt"
  run in_fixture 'require_clean_tree'
  [ "$status" -ne 0 ]
}

@test "require_clean_tree passes on a clean tree" {
  run in_fixture 'require_clean_tree'
  [ "$status" -eq 0 ]
}

@test "require_branch fails on the wrong branch" {
  run in_fixture 'require_branch build/demo'
  [ "$status" -ne 0 ]
  [[ "$output" == *main* ]]
}

# ---------------------------------------------------------------- load_env
@test "load_env does not echo secret values" {
  echo 'X_KEY=s3cret' > "$FIXTURE/.env"
  run in_fixture 'load_env; [[ "$X_KEY" == s3cret ]]'
  [ "$status" -eq 0 ]
  [[ "$output" != *s3cret* ]]
}

@test "main_root resolves to the main checkout from a worktree" {
  git -C "$FIXTURE" worktree add -q "$BATS_TEST_TMPDIR/wt" -b wt/test
  echo 'X_KEY=from-main-env' > "$FIXTURE/.env"
  run bash -c "cd '$BATS_TEST_TMPDIR/wt' && . '$REPO_ROOT/scripts/common.sh' && main_root"
  [ "$status" -eq 0 ]
  [ "$output" = "$FIXTURE" ]
  run bash -c "cd '$BATS_TEST_TMPDIR/wt' && . '$REPO_ROOT/scripts/common.sh' && load_env && echo \"\$KUBECONFIG\" && [[ \"\$X_KEY\" == from-main-env ]]"
  [ "$status" -eq 0 ]
  [[ "$output" == "$FIXTURE/.kube/argoconna26.yaml" ]]
}

@test "load_env puts TOOLS_BIN first" {
  local fake_usr="$BATS_TEST_TMPDIR/fake-usr-local" fake_tools="$BATS_TEST_TMPDIR/fake-tools"
  make_stub "$fake_usr" kubectl 'echo old'
  make_stub "$fake_tools" kubectl 'echo new'
  run bash -c "export PATH='$fake_usr':\$PATH TOOLS_BIN='$fake_tools'; cd '$FIXTURE'; . '$REPO_ROOT/scripts/common.sh'; load_env; command -v kubectl"
  [ "$status" -eq 0 ]
  [ "$output" = "$fake_tools/kubectl" ]
}

# ---------------------------------------------------------------- cluster_lock
start_holder() { # background process that holds the cluster lock until killed
  bash -c "cd '$FIXTURE'; . '$REPO_ROOT/scripts/common.sh'; cluster_lock; touch '$BATS_TEST_TMPDIR/held'; exec sleep 60" &
  HOLDER_PID=$!
  wait_file "$BATS_TEST_TMPDIR/held"
}

@test "cluster_lock refuses when held by an unrelated process" {
  start_holder
  run in_fixture 'cluster_lock'
  [ "$status" -eq 5 ]
  [[ "$output" == *"$HOLDER_PID"* ]]
}

@test "nested cluster_lock under the same holder proceeds" {
  cat > "$BATS_TEST_TMPDIR/child.sh" <<CHILD
. '$REPO_ROOT/scripts/common.sh'
cluster_lock
echo child-ok
CHILD
  cat > "$BATS_TEST_TMPDIR/Makefile" <<MK
t:
	@bash '$BATS_TEST_TMPDIR/child.sh'
MK
  cat > "$BATS_TEST_TMPDIR/outer.sh" <<OUTER
cd '$FIXTURE'
. '$REPO_ROOT/scripts/common.sh'
cluster_lock
bash '$BATS_TEST_TMPDIR/child.sh'
make -s -f '$BATS_TEST_TMPDIR/Makefile' t
# the lock is still held after the nested calls
( flock -n 9 ) 9<'$FIXTURE/.kube/cluster.lock' && { echo LOCK-RELEASED; exit 9; }
echo outer-ok
OUTER
  run bash "$BATS_TEST_TMPDIR/outer.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *child-ok*child-ok*outer-ok* ]]
}

@test "the lock is released when the holder exits" {
  run bash -c "cd '$FIXTURE'; . '$REPO_ROOT/scripts/common.sh'; cluster_lock"
  [ "$status" -eq 0 ]
  run in_fixture 'cluster_lock; echo got-it'
  [ "$status" -eq 0 ]
  [[ "$output" == *got-it* ]]
}

@test "a stale CLUSTER_LOCK_HELD does not bypass the lock" {
  start_holder
  CLUSTER_LOCK_HELD=999999 run in_fixture 'cluster_lock'
  [ "$status" -eq 5 ]
  # also not the PID of some other live process
  CLUSTER_LOCK_HELD=$$ run in_fixture 'cluster_lock'
  [ "$status" -eq 5 ]
}

# ---------------------------------------------------------------- check_fleet_disarmed
# kubectl stub: one Ready checkout pod; curl stub: Prometheus answers from files.
fleet_setup() {
  export FLEET_WAIT_S=2
  make_stub "$STUBS" kubectl 'case "$*" in
    "config current-context") echo kind-argoconna26 ;;
    *"get pods"*) cat "'"$BATS_TEST_TMPDIR"'/pods.json" ;;
  esac'
  make_stub "$STUBS" curl 'for a in "$@"; do q="$q $a"; done
    case "$q" in
      *checkout_config_upstream_timeout_ms*) cat "'"$BATS_TEST_TMPDIR"'/gauge.json" ;;
      *checkout_slo_target_percent*) cat "'"$BATS_TEST_TMPDIR"'/slo.json" ;;
      *checkout_requests_total*) cat "'"$BATS_TEST_TMPDIR"'/rate.json" ;;
    esac'
  echo '{"items":[{"metadata":{"name":"checkout-abc-1"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' > "$BATS_TEST_TMPDIR/pods.json"
  echo '{"data":{"result":[{"metric":{"pod":"checkout-abc-1"},"value":[1,"2000"]}]}}' > "$BATS_TEST_TMPDIR/gauge.json"
  echo '{"data":{"result":[{"metric":{},"value":[1,"99.9"]}]}}' > "$BATS_TEST_TMPDIR/rate.json"
  echo '{"data":{"result":[{"metric":{},"value":[1,"99"]}]}}' > "$BATS_TEST_TMPDIR/slo.json"
}

@test "check_fleet_disarmed passes when every Ready pod reports 2000 and the rate meets the SLO" {
  fleet_setup
  run in_fixture 'load_env; check_fleet_disarmed'
  [ "$status" -eq 0 ]
}

@test "check_fleet_disarmed fails when a checkout pod has no gauge series" {
  fleet_setup
  echo '{"data":{"result":[]}}' > "$BATS_TEST_TMPDIR/gauge.json"
  run in_fixture 'load_env; check_fleet_disarmed'
  [ "$status" -ne 0 ]
  [[ "$output" == *"no checkout_config_upstream_timeout_ms series"* ]]
}

@test "check_fleet_disarmed fails when the success-rate query is empty" {
  fleet_setup
  echo '{"data":{"result":[]}}' > "$BATS_TEST_TMPDIR/rate.json"
  run in_fixture 'load_env; check_fleet_disarmed'
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty or NaN"* ]]
}

@test "check_fleet_disarmed fails when the success rate is NaN" {
  fleet_setup
  echo '{"data":{"result":[{"metric":{},"value":[1,"NaN"]}]}}' > "$BATS_TEST_TMPDIR/rate.json"
  run in_fixture 'load_env; check_fleet_disarmed'
  [ "$status" -ne 0 ]
}

@test "check_fleet_disarmed fails when any checkout pod reports 200" {
  fleet_setup
  echo '{"data":{"result":[{"metric":{"pod":"checkout-abc-1"},"value":[1,"200"]}]}}' > "$BATS_TEST_TMPDIR/gauge.json"
  run in_fixture 'load_env; check_fleet_disarmed'
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected 2000"* ]]
}

@test "check_fleet_disarmed fails when the rate is below the SLO" {
  fleet_setup
  echo '{"data":{"result":[{"metric":{},"value":[1,"90.0"]}]}}' > "$BATS_TEST_TMPDIR/rate.json"
  run in_fixture 'load_env; check_fleet_disarmed'
  [ "$status" -ne 0 ]
  [[ "$output" == *"below"* ]]
}

@test "check_fleet_disarmed fails when no checkout pod is Ready" {
  fleet_setup
  echo '{"items":[]}' > "$BATS_TEST_TMPDIR/pods.json"
  run in_fixture 'load_env; check_fleet_disarmed'
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------- vendor
@test "vendor fails on a version mismatch" {
  make_stub "$STUBS" kind 'echo "kind v0.29.0 go1.24 linux/amd64"'
  run make -C "$REPO_ROOT" vendor TOOLS_BIN="$STUBS"
  [ "$status" -ne 0 ]
  [[ "$output" == *kind* ]]
  [[ "$output" == *v0.29.0* ]]
  [[ "$output" == *v0.33.0* ]]
}

# ---------------------------------------------------------------- helm_ensure
helm_setup() {
  echo 'a: 1' > "$BATS_TEST_TMPDIR/values.yaml"
  make_stub "$STUBS" helm 'echo "$*" >> "'"$BATS_TEST_TMPDIR"'/helm.calls"
    case "$*" in
      *" list "*) cat "'"$BATS_TEST_TMPDIR"'/list.json" ;;
      *" get values "*) cat "'"$BATS_TEST_TMPDIR"'/getvalues.json" ;;
    esac'
  echo '[{"name":"rel","status":"deployed","chart":"argo-cd-1.2.3"}]' > "$BATS_TEST_TMPDIR/list.json"
  echo '{"a":1}' > "$BATS_TEST_TMPDIR/getvalues.json"
}

@test "helm_ensure skips when chart version and values are unchanged" {
  helm_setup
  run in_fixture "load_env; helm_ensure rel argo/argo-cd 1.2.3 ns '$BATS_TEST_TMPDIR/values.yaml'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip: helm release rel"* ]]
  ! grep -q upgrade "$BATS_TEST_TMPDIR/helm.calls"
}

@test "helm_ensure upgrades when the values changed" {
  helm_setup
  echo 'a: 2' > "$BATS_TEST_TMPDIR/values.yaml"
  run in_fixture "load_env; helm_ensure rel argo/argo-cd 1.2.3 ns '$BATS_TEST_TMPDIR/values.yaml'"
  [ "$status" -eq 0 ]
  grep -q 'upgrade --install rel argo/argo-cd' "$BATS_TEST_TMPDIR/helm.calls"
}

@test "helm_ensure upgrades when the chart version changed" {
  helm_setup
  echo '[{"name":"rel","status":"deployed","chart":"argo-cd-1.2.2"}]' > "$BATS_TEST_TMPDIR/list.json"
  run in_fixture "load_env; helm_ensure rel argo/argo-cd 1.2.3 ns '$BATS_TEST_TMPDIR/values.yaml'"
  [ "$status" -eq 0 ]
  grep -q upgrade "$BATS_TEST_TMPDIR/helm.calls"
}
