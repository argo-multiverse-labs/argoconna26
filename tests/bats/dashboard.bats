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

# The off-the-shelf dashboards next to it (Argo CD, Argo Rollouts). Grafana runs near its memory
# limit, so none of them may refresh faster than 30 s.
GRAFANA_DIR="$REPO_ROOT/platform/grafana"

@test "every dashboard JSON is in the kustomization, and every listed file exists" {
  listed="$(yq -r '.configMapGenerator[].files[]' "$GRAFANA_DIR/kustomization.yaml" | sort)"
  present="$(cd "$GRAFANA_DIR" && ls ./*.json | sed 's#^\./##' | sort)"
  [ "$listed" = "$present" ] || { echo "listed: $listed"; echo "present: $present"; false; }
}

@test "the upstream dashboards refresh every 30 s or less often" {
  for f in dashboard-argocd.json dashboard-argo-rollouts.json; do
    r="$(jq -r '.refresh // ""' "$GRAFANA_DIR/$f")"
    case "$r" in
      ""|false|30s|1m|5m|15m|30m|1h) ;;
      *) echo "$f refreshes every $r"; false ;;
    esac
  done
}

@test "the upstream dashboards use only our Prometheus datasource (uid prometheus or \$datasource)" {
  for f in dashboard-argocd.json dashboard-argo-rollouts.json; do
    bad="$(jq -r '.. | objects | select(has("datasource")) | .datasource
      | if type == "object" then select(.type == "prometheus") | .uid else . end
      | select(. != null and . != "prometheus" and . != "$datasource" and . != "-- Grafana --")' "$GRAFANA_DIR/$f")"
    [ -z "$bad" ] || { echo "$f: $bad"; false; }
    v="$(jq -r '.templating.list[] | select(.name == "datasource") | .current.value' "$GRAFANA_DIR/$f")"
    [ "$v" = "prometheus" ] || { echo "$f: datasource variable defaults to $v"; false; }
  done
}

@test "the ServiceMonitors select the metrics Services the dashboards' job labels name" {
  sm="$GRAFANA_DIR/servicemonitors-argo.yaml"
  run yq -r 'select(.metadata.name == "argocd") | .spec.selector.matchExpressions[0].values[]' "$sm"
  [ "$status" -eq 0 ]
  for n in argocd-metrics argocd-server-metrics argocd-repo-server-metrics; do
    grep -qx "$n" <<<"$output" || { echo "missing $n"; false; }
  done
  run yq -r 'select(.metadata.name == "argo-rollouts") | .spec.namespaceSelector.matchNames[]' "$sm"
  [ "$output" = "argo-rollouts" ]
  jq -e '[.. | objects | select(has("expr")) | .expr | select(test("job=\"argo-rollouts-metrics\""))] | length > 0' \
    "$GRAFANA_DIR/dashboard-argo-rollouts.json" >/dev/null
}
