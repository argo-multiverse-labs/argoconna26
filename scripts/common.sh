#!/usr/bin/env bash
# Shared helpers. Source this file; do not execute it.
#   . "$(dirname "${BASH_SOURCE[0]}")/common.sh"; load_env
#
# Safety model: every cluster call goes through the isolated kubeconfig
# (<main checkout>/.kube/argoconna26.yaml) and an explicit --context, and
# require_context refuses anything but kind-argoconna26. Luke's default
# kubeconfig holds production contexts, so nothing here ever reads it.
#
# Exit codes: 1 generic, 3 wrong context, 4 wait timed out, 5 cluster lock held.

set -euo pipefail

COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The checkout this copy of common.sh belongs to (a worktree has its own).
COMMON_ROOT="$(dirname "$COMMON_SH_DIR")"
CLUSTER_LOCK_FD=200

# ---------------------------------------------------------------- logging
log_info()  { printf '%s\n' "$*" >&2; }
log_warn()  { printf 'warn: %s\n' "$*" >&2; }
log_error() { printf 'error: %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# ------------------------------------------------------------- repo paths
# The main checkout, even when called from inside a worktree (P12).
main_root() {
  dirname "$(git rev-parse --path-format=absolute --git-common-dir)"
}

# ---------------------------------------------------------------- load_env
# Order of precedence for TOOLS_BIN: caller's environment, then .env, then demo.env.
# Everything else: .env over demo.env over versions.env.
# Never echoes values.
load_env() {
  local caller_tools_bin="${TOOLS_BIN:-}" root envfile
  set -a
  # shellcheck disable=SC1091
  . "$COMMON_ROOT/versions.env"
  # shellcheck disable=SC1091
  . "$COMMON_ROOT/demo.env"
  root="$(main_root 2>/dev/null || true)"
  envfile="${root:+$root/.env}"
  if [[ -n "$envfile" && -r "$envfile" ]]; then
    # shellcheck disable=SC1090
    . "$envfile"
  fi
  set +a
  [[ -n "$caller_tools_bin" ]] && TOOLS_BIN="$caller_tools_bin"
  export TOOLS_BIN
  # P25: the pinned tools win on PATH, unless TOOLS_BIN is already first.
  case ":$PATH:" in
    ":$TOOLS_BIN:"*) ;;
    *) PATH="$TOOLS_BIN:$PATH" ;;
  esac
  export PATH
  if [[ -n "$root" ]]; then
    KUBECONFIG="$root/$KUBECONFIG_REL"
    # Helm state is isolated too, so the demo never edits Luke's helm repo list.
    HELM_CONFIG_HOME="$root/.kube/helm/config"
    HELM_CACHE_HOME="$root/.kube/helm/cache"
    HELM_DATA_HOME="$root/.kube/helm/data"
    export KUBECONFIG HELM_CONFIG_HOME HELM_CACHE_HOME HELM_DATA_HOME
  fi
}

# ------------------------------------------------------------ cluster guard
_isolated_kubeconfig() { printf '%s/%s' "$(main_root)" "${KUBECONFIG_REL:-.kube/argoconna26.yaml}"; }

# Exit 3 unless the isolated kubeconfig is in use and its current context is the demo's.
require_context() {
  local want="${CLUSTER_CONTEXT:-kind-argoconna26}" iso got
  iso="$(_isolated_kubeconfig)"
  if [[ "${KUBECONFIG:-}" != "$iso" ]]; then
    log_error "refusing: KUBECONFIG must be the isolated file $iso (got '${KUBECONFIG:-unset}')"
    return 3
  fi
  got="$(kubectl config current-context 2>/dev/null || true)"
  if [[ "$got" != "$want" ]]; then
    log_error "refusing: current context is '${got:-none}', not '$want'"
    return 3
  fi
}

# kubectl pinned to the demo cluster. Dies rather than touch any other kubeconfig.
k() {
  [[ "${KUBECONFIG:-}" == "$(_isolated_kubeconfig)" ]] \
    || die "refusing kubectl: KUBECONFIG is not the isolated demo kubeconfig"
  kubectl --context "${CLUSTER_CONTEXT:-kind-argoconna26}" "$@"
}

# helm pinned the same way.
h() {
  [[ "${KUBECONFIG:-}" == "$(_isolated_kubeconfig)" ]] \
    || die "refusing helm: KUBECONFIG is not the isolated demo kubeconfig"
  helm --kubeconfig "$KUBECONFIG" --kube-context "${CLUSTER_CONTEXT:-kind-argoconna26}" "$@"
}

# ------------------------------------------------------------------ waiting
# wait_for DESC TIMEOUT_S CMD...   polls every 2 s; exit 4 on timeout (and prints DESC).
wait_for() {
  local desc="$1" timeout="$2"; shift 2
  local deadline=$((SECONDS + timeout))
  log_info "waiting for: $desc (up to ${timeout}s)"
  while true; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    if (( SECONDS >= deadline )); then
      log_error "timed out after ${timeout}s waiting for: $desc"
      return 4
    fi
    sleep 2
  done
}

# -------------------------------------------------------------- git guards
require_clean_tree() {
  [[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
}

require_branch() {
  local want="$1" got
  got="$(git rev-parse --abbrev-ref HEAD)"
  [[ "$got" == "$want" ]] || die "on branch '$got', expected '$want'"
}

# ------------------------------------------------------------ cluster lock
# Re-entrant for descendants of the holder. The outermost caller holds an flock on
# fd 200 for the life of its process and exports CLUSTER_LOCK_HELD=<its PID>. Children
# inherit both. A caller proceeds without re-locking only when CLUSTER_LOCK_HELD is the
# PID recorded in the lock file, that PID is alive, and the lock really is held.
# Anyone else exits 5 naming the holder.
_lock_file() { printf '%s/.kube/cluster.lock' "$(main_root)"; }

_lock_is_held() { # true when some open file description holds the flock
  ! ( flock -n 9 ) 9<"$1" 2>/dev/null
}

cluster_lock() {
  local lockfile holder_pid holder_info
  lockfile="$(_lock_file)"
  mkdir -p "$(dirname "$lockfile")"
  touch "$lockfile"

  if [[ -n "${CLUSTER_LOCK_HELD:-}" ]]; then
    holder_pid="$(awk 'NR==1 {print $1}' "$lockfile" 2>/dev/null || true)"
    if [[ "$holder_pid" == "$CLUSTER_LOCK_HELD" ]] \
       && kill -0 "$holder_pid" 2>/dev/null \
       && _lock_is_held "$lockfile"; then
      return 0
    fi
  fi

  eval "exec ${CLUSTER_LOCK_FD}>>\"\$lockfile\""
  if ! flock -n "$CLUSTER_LOCK_FD"; then
    holder_info="$(head -n1 "$lockfile" 2>/dev/null || true)"
    log_error "cluster lock is held by: ${holder_info:-unknown holder}"
    eval "exec ${CLUSTER_LOCK_FD}>&-"
    exit 5
  fi
  printf '%s %s\n' "$$" "$(ps -o args= -p "$$" 2>/dev/null | cut -c1-120)" > "$lockfile"
  export CLUSTER_LOCK_HELD="$$"
}

# ------------------------------------------------------ fleet disarmed check
# One shared check (Tasks 3.16, 6.3, 6.5). Every Ready checkout pod must have a
# gauge series in Prometheus, every value must be CONFIG_HEALTHY, and the 1 m
# success rate must meet checkout_slo_target_percent. A missing series, an empty
# result or a NaN rate is a FAIL with a reason, never a pass.
_prom_query() { # EXPR -> JSON on stdout
  curl -sf --max-time 10 --get --data-urlencode "query=$1" "${PROM_HOST_URL}/api/v1/query"
}

_ready_checkout_pods() {
  k get pods -n "$NS_DEMO" -l "$CHECKOUT_POD_SELECTOR" -o json \
    | jq -r '.items[]
        | select(.metadata.deletionTimestamp == null)
        | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
        | .metadata.name' | sort
}

_gauge_pods() {
  _prom_query "checkout_config_upstream_timeout_ms{namespace=\"$NS_DEMO\"}" \
    | jq -r '.data.result[] | "\(.metric.pod) \(.value[1])"' | sort
}

_fleet_gauge_complete() {
  local pods gauge p
  pods="$(_ready_checkout_pods)"
  [[ -n "$pods" ]] || return 1
  gauge="$(_gauge_pods)"
  while read -r p; do
    grep -q "^$p " <<<"$gauge" || return 1
  done <<<"$pods"
}

check_fleet_disarmed() {
  local pods gauge p v rate slo
  pods="$(_ready_checkout_pods)" || { log_error "FAIL: cannot list checkout pods"; return 1; }
  if [[ -z "$pods" ]]; then
    log_error "FAIL: no Ready checkout pods"
    return 1
  fi
  if ! wait_for "a ${CONFIG_KEY} gauge series for every Ready checkout pod" \
        "${FLEET_WAIT_S:-90}" _fleet_gauge_complete; then
    log_error "FAIL: a Ready checkout pod has no checkout_config_upstream_timeout_ms series"
    return 1
  fi
  gauge="$(_gauge_pods)"
  while read -r p; do
    v="$(awk -v p="$p" '$1 == p {print $2}' <<<"$gauge")"
    if [[ "$v" != "$CONFIG_HEALTHY" ]]; then
      log_error "FAIL: pod $p reports ${CONFIG_KEY}=${v}, expected ${CONFIG_HEALTHY}"
      return 1
    fi
  done <<<"$pods"

  rate="$(_prom_query "100 * sum(rate(checkout_requests_total{namespace=\"$NS_DEMO\",code!~\"5..\"}[1m])) / sum(rate(checkout_requests_total{namespace=\"$NS_DEMO\"}[1m]))" \
          | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true)"
  if [[ -z "$rate" || "$rate" == "NaN" ]]; then
    log_error "FAIL: the 1m checkout success-rate query is empty or NaN"
    return 1
  fi
  slo="$(_prom_query "max(checkout_slo_target_percent{namespace=\"$NS_DEMO\"})" \
          | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true)"
  if [[ -z "$slo" || "$slo" == "NaN" ]]; then
    log_error "FAIL: checkout_slo_target_percent has no series"
    return 1
  fi
  if ! awk -v r="$rate" -v s="$slo" 'BEGIN {exit !(r + 0 >= s + 0)}'; then
    log_error "FAIL: 1m success rate ${rate}% is below the ${slo}% target"
    return 1
  fi
  log_info "fleet disarmed: all Ready pods at ${CONFIG_HEALTHY}, success rate ${rate}% >= ${slo}%"
}
