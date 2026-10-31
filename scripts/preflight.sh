#!/usr/bin/env bash
# Pre-flight checks. Exits 1 on any FAIL.   scripts/preflight.sh [RUNG]
# Sections are functions named section_<name>. V1_SECTIONS runs first, in order; any other
# section_* function defined by a later slice runs after them (alphabetically).
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PASS=0
FAIL=0
WARN=0
check_pass() { printf '  \033[0;32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
check_fail() { printf '  \033[0;31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
check_warn() { printf '  \033[0;33m[WARN]\033[0m %s\n' "$1"; WARN=$((WARN + 1)); }

V1_SECTIONS=(tools context cluster nodes pods endpoints)

section_tools() {
  local out
  if out="$("$COMMON_SH_DIR/vendor-check.sh" 2>&1)"; then
    check_pass "tools: all present at the pinned versions"
  else
    while IFS= read -r line; do check_fail "$line"; done <<<"$out"
  fi
}

section_context() {
  local out
  if out="$(require_context 2>&1)"; then
    check_pass "kube context is $CLUSTER_CONTEXT on the isolated kubeconfig"
  else
    check_fail "kube context guard: $out"
  fi
}

section_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    check_pass "kind cluster '$CLUSTER_NAME' exists"
  else
    check_fail "kind cluster '$CLUSTER_NAME' does not exist"
  fi
}

# A stopped kind container still passes require_context (it reads only the local
# kubeconfig), so every cluster read below is guarded: a failed kubectl is a FAIL line
# with a reason, never a silent errexit before the summary.
_api_up() { k get --raw=/readyz >/dev/null 2>&1; }

section_nodes() {
  local json not_ready total
  if ! json="$(k get nodes -o json 2>/dev/null)"; then
    check_fail "API server unreachable: cannot list nodes"
    return 0
  fi
  total="$(jq '.items | length' <<<"$json")"
  not_ready="$(jq -r '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status != "True")) | .metadata.name] | join(" ")' <<<"$json")"
  if [[ "$total" -ge 1 && -z "$not_ready" ]]; then
    check_pass "all $total nodes Ready"
  else
    check_fail "nodes not Ready: ${not_ready:-none found}"
  fi
}

section_pods() {
  local ns json bad count
  if ! _api_up; then
    check_fail "API server unreachable: pods not checked"
    return 0
  fi
  for ns in "$NS_ARGOCD" "$NS_ROLLOUTS" "$NS_MONITORING"; do
    if ! k get namespace "$ns" >/dev/null 2>&1; then
      check_fail "namespace $ns does not exist"; continue
    fi
    if ! json="$(k get pods -n "$ns" -o json 2>/dev/null)"; then
      check_fail "cannot list pods in $ns"; continue
    fi
    count="$(jq '[.items[] | select(.status.phase != "Succeeded")] | length' <<<"$json")"
    bad="$(jq -r '
      [.items[] | select(.status.phase != "Succeeded")
       | select(any(.status.conditions[]?; .type == "Ready" and .status == "True") | not)
       | .metadata.name] | join(" ")' <<<"$json")"
    if [[ "$count" -ge 1 && -z "$bad" ]]; then
      check_pass "every pod Ready in $ns ($count)"
    else
      check_fail "pods not Ready in $ns: ${bad:-none running}"
    fi
  done
}

section_endpoints() {
  if [[ "$(curl -s --max-time 5 "$ARGOCD_HOST_URL/healthz" || true)" == "ok" ]]; then
    check_pass "Argo CD answers on $ARGOCD_HOST_URL"
  else
    check_fail "Argo CD does not answer on $ARGOCD_HOST_URL"
  fi
  if curl -sf --max-time 5 "$GRAFANA_HOST_URL/api/health" >/dev/null; then
    check_pass "Grafana answers on $GRAFANA_HOST_URL"
  else
    check_fail "Grafana does not answer on $GRAFANA_HOST_URL"
  fi
  if curl -sf --max-time 5 "$PROM_HOST_URL/-/ready" >/dev/null; then
    check_pass "Prometheus is ready on $PROM_HOST_URL"
  else
    check_fail "Prometheus is not ready on $PROM_HOST_URL"
  fi
}

main() {
  local rung="${1:-}" s extra
  load_env
  echo "============================================"
  echo " ArgoCon NA 2026 demo: pre-flight${rung:+ (rung $rung)}"
  echo "============================================"
  # Without the isolated context nothing else may touch the cluster.
  if ! require_context 2>/dev/null; then
    section_context
    section_cluster
    echo; echo "Result: $PASS passed, $FAIL failed, $WARN warnings"
    exit 1
  fi
  for s in "${V1_SECTIONS[@]}"; do
    echo "--- $s ---"
    "section_$s"
  done
  while read -r extra; do
    [[ " ${V1_SECTIONS[*]} " == *" ${extra#section_} "* ]] && continue
    echo "--- ${extra#section_} ---"
    "$extra"
  done < <(compgen -A function section_ | sort)
  echo
  echo "Result: $PASS passed, $FAIL failed, $WARN warnings"
  (( FAIL == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
