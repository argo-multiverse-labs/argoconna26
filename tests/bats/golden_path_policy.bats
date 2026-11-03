#!/usr/bin/env bats
# The golden-path policy against fixtures (conftest only; no cluster)

load helpers

ct() { run conftest test --policy "$REPO_ROOT/policy" --namespace goldenpath "$REPO_ROOT/policy/fixtures/golden_path/$1.yaml"; }

@test "good fixture passes" {
  ct good
  [ "$status" -eq 0 ]
}

@test "missing owner label is denied" {
  ct missing_owner
  [ "$status" -ne 0 ]
  [[ "$output" == *"example.dev/owner"* ]]
}

@test "missing slo label is denied" {
  ct missing_slo
  [ "$status" -ne 0 ]
  [[ "$output" == *"slo.example.dev/success-rate"* ]]
}

@test "the real apps pass" {
  cd "$REPO_ROOT"
  for d in apps/checkout apps/pricing apps/loadgen; do
    kubectl kustomize "$d" | conftest test --policy policy --namespace goldenpath --parser yaml -
  done
}

@test "an app that drops a pod-template label fails policy-check" {
  cd "$REPO_ROOT"
  run bash -c "kubectl kustomize apps/pricing | sed '/^      labels:/,/^    spec:/{/slo.example.dev/d}' | conftest test --policy policy --namespace goldenpath --parser yaml -"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pod template"* ]]
}
