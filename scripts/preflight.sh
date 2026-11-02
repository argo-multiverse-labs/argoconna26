#!/usr/bin/env bash
# Pre-flight checks. Exits 1 on any FAIL.   scripts/preflight.sh [RUNG] [--armed] [--pre-promotion] [--job-run] [--quiet]
#   --armed          rung 3 is promoted: autonomy on the tracked branch must be act
#   --pre-promotion  autonomy must still be propose (rung 3, before the promotion PR merges)
#   --job-run        running inside the scheduled unit: GH_TOKEN (from job.env) is the credential,
#                    and the github-admin section (Luke's admin login) is skipped
#   --quiet          print only failures; exit status is the same
# Sections are functions named section_<name>. V1_SECTIONS runs first, in order; any other
# section_* function defined by a later slice runs after them (alphabetically).
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PASS=0
FAIL=0
WARN=0
RUNG=""
ARMED=0
PRE_PROMOTION=0
JOB_RUN=0
QUIET=0
check_pass() { ((QUIET)) || printf '  \033[0;32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
check_fail() { printf '  \033[0;31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
check_warn() { ((QUIET)) || printf '  \033[0;33m[WARN]\033[0m %s\n' "$1"; WARN=$((WARN + 1)); }
say() { ((QUIET)) || printf '%s\n' "$*"; }

parse_args() {
  local a
  for a in "$@"; do
    case "$a" in
      --armed) ARMED=1 ;;
      --pre-promotion) PRE_PROMOTION=1 ;;
      --job-run) JOB_RUN=1 ;;
      --quiet) QUIET=1 ;;
      --*) echo "preflight: unknown option $a" >&2; exit 2 ;;
      *) RUNG="$a" ;;
    esac
  done
}

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

# llm: the proxy answers on the rca alias, the holmes key has budget left, and the build's
# cumulative spend (exports of earlier clusters plus the live proxy) is under LLM_BUDGET_USD.
section_llm() {
  local key code info left live cum
  # shellcheck source=scripts/litellm.sh
  . "$COMMON_SH_DIR/litellm.sh"
  if ! _have LITELLM_MASTER_KEY LLM_BUDGET_USD; then
    check_fail "llm: LITELLM_MASTER_KEY or LLM_BUDGET_USD is missing in .env"; return 0
  fi
  if ! curl -sf --max-time 5 "${LITELLM_HOST_URL}/health/readiness" >/dev/null; then
    check_fail "llm: LiteLLM does not answer on $LITELLM_HOST_URL"; return 0
  fi
  key="$(stored_key holmes-llm)"
  if [[ -z "$key" ]]; then
    check_fail "llm: Secret holmes-llm is missing (make litellm-keys)"; return 0
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -X POST -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$LLM_ALIAS_RCA" '{model: $m, max_tokens: 5, messages: [{role: "user", content: "Reply ok."}]}')" \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$key") "${LITELLM_HOST_URL}/v1/chat/completions" || true)"
  if [[ "$code" == 200 ]]; then
    check_pass "llm: a max_tokens 5 completion on alias $LLM_ALIAS_RCA returns 200"
  else
    check_fail "llm: completion on alias $LLM_ALIAS_RCA returned HTTP ${code:-none}"
  fi
  if info="$(llm_call "$key" GET /key/info 2>/dev/null)"; then
    left="$(jq -r '((.info.max_budget // 0) - (.info.spend // 0))' <<<"$info")"
    if awk -v l="$left" 'BEGIN { exit !(l > 5) }'; then
      check_pass "llm: the holmes key has \$$(printf '%.2f' "$left") left"
    else
      check_fail "llm: the holmes key has only \$$(printf '%.2f' "$left") left (need more than \$5)"
    fi
  else
    check_fail "llm: GET /key/info failed for the holmes key"
  fi
  live="$(live_spend 2>/dev/null || echo 0)"
  cum="$(spend_total "$(spend_dir)" "$live")"
  if awk -v c="$cum" -v b="$LLM_BUDGET_USD" 'BEGIN { exit !(c <= b) }'; then
    check_pass "$(awk -v l="$live" -v c="$cum" -v b="$LLM_BUDGET_USD" 'BEGIN { printf "llm: this cluster has $%.2f of $%.2f left; the build has spent $%.2f in all", b - l, b, c }')"
  else
    check_fail "llm: the build has spent \$$cum, over LLM_BUDGET_USD (\$$LLM_BUDGET_USD)"
  fi
}

# bridge_hooks (every rung): the test-hook Secret bridge-env must not exist, and the running
# bridge must report no test hook active. A failure-paths run that was killed leaves it behind,
# and then every live incident is refused or handed off (Task 4.6). Key names only, never values.
section_bridge_hooks() {
  local json keys status
  if ! _api_up; then
    check_fail "API server unreachable: bridge-env not checked"; return 0
  fi
  if ! json="$(k get secret bridge-env -n "$NS_AIOPS" --ignore-not-found -o json 2>/dev/null)"; then
    check_fail "cannot read Secret bridge-env in $NS_AIOPS"; return 0
  fi
  if [[ -z "$json" ]]; then
    check_pass "no bridge-env Secret (no bridge test hooks)"
  else
    keys="$(jq -r '(.data // {}) | keys | join(" ")' <<<"$json")"
    check_fail "Secret bridge-env exists (${keys:-no keys}): run make bridge-hooks-clear"
  fi
  if ! status="$(curl -sf --max-time 5 "127.0.0.1:${PORT_BRIDGE}/status")"; then
    check_warn "bridge /status does not answer on port $PORT_BRIDGE: test hooks not checked"
  elif jq -e '.test_hooks_active == false' >/dev/null <<<"$status"; then
    check_pass "bridge /status: no test hook active"
  else
    check_fail "bridge /status: test hooks active (confidence_threshold $(jq -r .confidence_threshold <<<"$status"), holmes_timeout_s $(jq -r .holmes_timeout_s <<<"$status")): run make bridge-hooks-clear"
  fi
}

# job (rung 3): the GitHub-side state the scheduled job needs, from the operator credential
# alone (GH_TOKEN inside the unit, Luke's gh login outside it). With --armed it also reads
# (never changes) the rules on the tracked branch: the required policy-check must be live.
# github-admin (Task 4.5 Step 2) is deferred and never runs under --job-run. The App
# installation permission checks (section_github_runtime) are still to come with L5b.
section_job() {
  local want="" lvl code
  [[ "$RUNG" == 3 ]] || return 0
  if ((JOB_RUN)); then
    if [[ -z "${GH_TOKEN:-}" ]]; then
      check_fail "job: GH_TOKEN is not set (job.env missing from the unit environment)"; return 0
    fi
  fi
  if gh api user --jq .login >/dev/null 2>&1; then
    check_pass "job: the operator credential authenticates with gh$( ((JOB_RUN)) && printf " (GH_TOKEN)")"
  else
    check_fail "job: gh api user failed (credential rejected or GitHub unreachable)"; return 0
  fi
  if ((ARMED)); then want=act; elif ((PRE_PROMOTION)); then want=propose; fi
  if [[ -n "$want" ]]; then
    lvl="$(tracked_autonomy_level || true)"
    if [[ "$lvl" == "$want" ]]; then
      check_pass "job: autonomy on $TRACKED_BRANCH is $want"
    else
      check_fail "job: autonomy on $TRACKED_BRANCH is '${lvl:-unreadable}', expected $want"
    fi
  fi
  # Armed rung 3 relies on GitHub refusing to merge without the check, so read (never change) the
  # rules that apply to the tracked branch. Read access is enough, so this runs before L5b.
  if ((ARMED)); then
    local rules
    rules="$(gh api "repos/${REPO_SLUG}/rules/branches/${TRACKED_BRANCH}" 2>/dev/null || true)"
    if jq -e --arg c "$POLICY_CHECK_CONTEXT" --argjson i "$POLICY_CHECK_INTEGRATION_ID" \
        'any(.[]?; .type == "required_status_checks"
             and any(.parameters.required_status_checks[]?; .context == $c and .integration_id == $i))' \
        <<<"${rules:-[]}" >/dev/null 2>&1; then
      check_pass "job: $TRACKED_BRANCH requires $POLICY_CHECK_CONTEXT (integration $POLICY_CHECK_INTEGRATION_ID)"
    else
      check_fail "job: $TRACKED_BRANCH does not require $POLICY_CHECK_CONTEXT (integration $POLICY_CHECK_INTEGRATION_ID); act would merge on the bridge's fallback alone"
    fi
  fi
  code="$(gh api -X GET "repos/${REPO_SLUG}/contents/.github/CODEOWNERS?ref=${TRACKED_BRANCH}" --jq .name 2>/dev/null || true)"
  if [[ "$code" == CODEOWNERS ]]; then
    check_pass "job: CODEOWNERS exists on $TRACKED_BRANCH"
  else
    check_fail "job: .github/CODEOWNERS not found on $TRACKED_BRANCH"
  fi
}

main() {
  local s extra
  parse_args "$@"
  load_env
  say "============================================"
  say " ArgoCon NA 2026 demo: pre-flight${RUNG:+ (rung $RUNG)}"
  say "============================================"
  # Without the isolated context nothing else may touch the cluster.
  if ! require_context 2>/dev/null; then
    section_context
    section_cluster
    say; say "Result: $PASS passed, $FAIL failed, $WARN warnings"
    exit 1
  fi
  for s in "${V1_SECTIONS[@]}"; do
    say "--- $s ---"
    "section_$s"
  done
  while read -r extra; do
    [[ " ${V1_SECTIONS[*]} " == *" ${extra#section_} "* ]] && continue
    # The scheduled job runs with GH_TOKEN only: Luke's admin checks are the caller's job.
    if ((JOB_RUN)) && [[ "$extra" == section_github_admin ]]; then continue; fi
    say "--- ${extra#section_} ---"
    "$extra"
  done < <(compgen -A function section_ | sort)
  say
  say "Result: $PASS passed, $FAIL failed, $WARN warnings"
  (( FAIL == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
