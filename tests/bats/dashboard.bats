#!/usr/bin/env bats
# The trust-ladder dashboard's queries. Every bridge restart (each reset deletes the pod) starts a
# new series with a new pod label, so an unaggregated aiops_* query shows one tile per pod.

load helpers

DASH="$REPO_ROOT/platform/grafana/dashboard-trust-ladder.json"

@test "every aiops_* query on the dashboard aggregates across pods" {
  run jq -r '.. | objects | select(has("expr")) | .expr | select(test("aiops_"))' "$DASH"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  bad="$(grep -Ev '^(sum|max|min|avg)( by \([a-z_, ]+\))? ?\(' <<<"$output" || true)"
  [ -z "$bad" ] || { echo "unaggregated: $bad"; false; }
}
