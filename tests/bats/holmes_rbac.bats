#!/usr/bin/env bats
# Tests for scripts/holmes-rbac.sh: the read-only check on a rendered role, and the allow-list.

load helpers

role() { # RULES_YAML : a ClusterRole document
  printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRole\nmetadata:\n  name: holmes\nrules:\n%s\n' "$1" > "$BATS_TEST_TMPDIR/role.yaml"
}

check() { ( . "$REPO_ROOT/scripts/holmes-rbac.sh"; check_rules "$BATS_TEST_TMPDIR/role.yaml" ); }

@test "a get/list/watch role on ordinary resources passes" {
  role $'  - apiGroups: [""]\n    resources: [pods, pods/log, configmaps]\n    verbs: [get, list, watch]\n  - apiGroups: [argoproj.io]\n    resources: [rollouts]\n    verbs: [get, list]'
  run check
  [ "$status" -eq 0 ]
}

@test "a write verb is refused" {
  role $'  - apiGroups: [""]\n    resources: [pods]\n    verbs: [get, patch]'
  run check
  [ "$status" -ne 0 ]
  [[ "$output" == *"verb patch"* ]]
}

@test "secrets are refused, also as a read" {
  role $'  - apiGroups: [""]\n    resources: [secrets]\n    verbs: [get]'
  run check
  [ "$status" -ne 0 ]
  [[ "$output" == *"secrets"* ]]
}

@test "a wildcard resource or group is refused" {
  role $'  - apiGroups: ["*"]\n    resources: [pods]\n    verbs: [get]'
  run check
  [ "$status" -ne 0 ]
  role $'  - apiGroups: [""]\n    resources: ["*"]\n    verbs: [get]'
  run check
  [ "$status" -ne 0 ]
}

@test "exec, proxy and token subresources are refused" {
  for r in pods/exec pods/portforward services/proxy serviceaccounts/token; do
    role "  - apiGroups: [\"\"]"$'\n'"    resources: [$r]"$'\n'"    verbs: [get]"
    run check
    [ "$status" -ne 0 ]
  done
}

@test "a file without a role fails" {
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n' > "$BATS_TEST_TMPDIR/role.yaml"
  run check
  [ "$status" -ne 0 ]
}

@test "the cdevents-timeline allow-list admits /timeline and /incidents only, and refuses a .. traversal" {
  command -v docker >/dev/null || skip "docker not available"
  docker image inspect "robustadev/holmes:0.45.0" >/dev/null 2>&1 || skip "HolmesGPT image not present locally"
  run "$REPO_ROOT/scripts/holmes-rbac.sh" allowlist
  [ "$status" -eq 0 ]
  [[ "$output" == *"refused  http://cdevents-sim.aiops.svc:8080/timeline/../events"* ]]
  [[ "$output" != *"FAIL"* ]]
}
