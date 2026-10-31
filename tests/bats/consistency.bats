#!/usr/bin/env bats
# Tests for scripts/check-consistency.sh

load helpers

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  cp -r "$REPO_ROOT/tests/bats/fixtures/consistency/." "$WORK/"
  git -C "$WORK" init -q -b main
  git -C "$WORK" config user.email t@example.invalid
  git -C "$WORK" config user.name t
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m fixture
}

plant() { # FILE LINE : append an offence to a tracked file and commit it
  printf '%s\n' "$2" >> "$WORK/$1"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m plant
}

@test "clean fixture prints consistency: OK" {
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "consistency: OK" ]
}

@test "flags a different kindest/node tag" {
  plant cluster.sh '# image: kindest/node:v1.32.11'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cluster.sh:5:"* ]]
}

@test "flags a hardcoded chart --version" {
  plant Makefile $'\thelm upgrade --install kps prom/kube-prometheus-stack --version 80.1.0'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Makefile:4:"* ]]
}

@test "flags an unknown namespace literal" {
  plant cluster.sh 'kubectl get pods -n observability'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cluster.sh:5:"* ]]
  [[ "$output" == *observability* ]]
}

@test "flags an unknown namespace in a manifest" {
  plant deploy.yaml '  namespace: scratch'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"deploy.yaml:4:"* ]]
}

@test "flags a foreign kind context" {
  plant cluster.sh 'kubectl --context kind-other get nodes'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cluster.sh:5:"* ]]
}

@test "untracked files are not scanned" {
  printf 'kubectl get pods -n observability\n' > "$WORK/untracked.sh"
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "consistency: OK" ]
}
