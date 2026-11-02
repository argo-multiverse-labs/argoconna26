#!/usr/bin/env bats
# scripts/policy-check.sh: the local twin of the policy-check Action (no cluster)

load helpers

@test "golden path alone passes on the real apps" {
  run "$REPO_ROOT/scripts/policy-check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"apps/checkout/"* ]]
}

@test "--base without --head is a usage error" {
  run "$REPO_ROOT/scripts/policy-check.sh" --base abc
  [ "$status" -eq 2 ]
}

@test "a human author skips the auto-fix rules" {
  head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  run "$REPO_ROOT/scripts/policy-check.sh" --base "$head" --head "$head" --author-login someone
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-fix rules skipped"* ]]
}

@test "a bot PR with no diff fails closed" {
  head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  run "$REPO_ROOT/scripts/policy-check.sh" --base "$head" --head "$head" --body-file /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"rule 1:"* ]]
}
