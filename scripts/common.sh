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
# Under STAGE=1 (P19) a log line longer than STAGE_COLS is cut to fit the stage pane, and
# the full line goes to <main checkout>/.operator/stage.log, so nothing is lost.
_log()      { _stage_fit "$1$2" >&2; }
log_info()  { _log '' "$*"; }
log_warn()  { _log 'warn: ' "$*"; }
log_error() { _log 'error: ' "$*"; }
die()       { log_error "$*"; exit 1; }

# ------------------------------------------------------------- repo paths
# The main checkout, even when called from inside a worktree (P12).
main_root() {
  dirname "$(git rev-parse --path-format=absolute --git-common-dir)"
}

# ---------------------------------------------------------------- load_env
# Order of precedence for TOOLS_BIN: caller's environment, then .env, then demo.env.
# An empty value counts as unset, so a blank `TOOLS_BIN=` never puts "" (the cwd) on PATH.
# Everything else: .env over demo.env over versions.env, except the guard variables: the
# cluster guard (CLUSTER_NAME, CLUSTER_CONTEXT, KUBECONFIG_REL) and the push target
# (TRACKED_BRANCH, REPO_SLUG, and OPERATOR_REMOTE, which only a caller's environment may
# set, for tests). .env can't change them: load_env returns 3 when it tries.
# Never echoes values.
load_env() {
  local caller_tools_bin="${TOOLS_BIN:-}" root envfile demo_tools_bin guard_vars guard_var
  local -A guard=()
  guard_vars=(CLUSTER_NAME CLUSTER_CONTEXT KUBECONFIG_REL TRACKED_BRANCH REPO_SLUG OPERATOR_REMOTE)
  set -a
  # shellcheck disable=SC1091
  . "$COMMON_ROOT/versions.env"
  # shellcheck disable=SC1091
  . "$COMMON_ROOT/demo.env"
  set +a
  demo_tools_bin="${TOOLS_BIN:-}"
  for guard_var in "${guard_vars[@]}"; do guard["$guard_var"]="${!guard_var:-}"; done
  root="$(main_root 2>/dev/null || true)"
  envfile="${root:+$root/.env}"
  if [[ -n "$envfile" && -r "$envfile" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$envfile"
    set +a
  fi
  for guard_var in "${guard_vars[@]}"; do
    if [[ "${!guard_var:-}" != "${guard[$guard_var]}" ]]; then
      log_error "refusing: .env sets $guard_var; it comes from demo.env (or the caller) only"
      return 3
    fi
  done
  TOOLS_BIN="${caller_tools_bin:-${TOOLS_BIN:-}}"
  [[ -n "$TOOLS_BIN" ]] || TOOLS_BIN="$demo_tools_bin"
  export TOOLS_BIN
  # P25: the pinned tools win on PATH, unless TOOLS_BIN is already first.
  if [[ -n "$TOOLS_BIN" ]]; then
    case ":$PATH:" in
      ":$TOOLS_BIN:"*) ;;
      *) PATH="$TOOLS_BIN:$PATH" ;;
    esac
  fi
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

# _lock_openers FILE : "PID (command)" for every process with FILE open, so an orphan that
# inherited the lock fd (its parent killed without cleanup) is easy to find; "none found" if none.
_lock_openers() {
  local f fd pid out=()
  f="$(readlink -f "$1")"
  for fd in /proc/[0-9]*/fd/*; do
    [[ "$(readlink "$fd" 2>/dev/null)" == "$f" ]] || continue
    pid="${fd#/proc/}" pid="${pid%%/*}"
    [[ " ${out[*]} " == *" $pid ("* ]] && continue
    out+=("$pid ($(cat "/proc/$pid/comm" 2>/dev/null || echo '?'))")
  done
  if ((${#out[@]})); then printf '%s' "${out[*]}"; else printf 'none found'; fi
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
    eval "exec ${CLUSTER_LOCK_FD}>&-"
    log_error "cluster lock is held by: ${holder_info:-unknown holder}; open by: $(_lock_openers "$lockfile")"
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

# One line per pod: "POD VALUES", where VALUES joins the distinct values of every series
# that pod has. A pod scraped through two Services (canary and stable) has two series;
# they collapse to "2000" when they agree, and "200,2000" (a FAIL) when they don't.
_gauge_pods() {
  _prom_query "checkout_config_upstream_timeout_ms{namespace=\"$NS_DEMO\"}" \
    | jq -r '.data.result | group_by(.metric.pod)[]
        | "\(.[0].metric.pod) \([.[].value[1]] | unique | join(","))"' | sort
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

_fleet_success_rate() {
  _prom_query "100 * sum(rate(checkout_requests_total{namespace=\"$NS_DEMO\",code!~\"5..\"}[1m])) / sum(rate(checkout_requests_total{namespace=\"$NS_DEMO\"}[1m]))" \
    | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true
}

_rate_meets_slo() { awk -v r="$1" -v s="$2" 'BEGIN {exit !(r + 0 >= s + 0)}'; }

_fleet_rate_recovered() { _rate_meets_slo "$(_fleet_success_rate)" "$SLO_NOW"; }

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
  gauge="$(_gauge_pods)" || { log_error "FAIL: Prometheus stopped answering the gauge query"; return 1; }
  while read -r p; do
    v="$(awk -v p="$p" '$1 == p {print $2}' <<<"$gauge")"
    if [[ "$v" != "$CONFIG_HEALTHY" ]]; then
      log_error "FAIL: pod $p reports ${CONFIG_KEY}=${v}, expected ${CONFIG_HEALTHY}"
      return 1
    fi
  done <<<"$pods"

  slo="$(_prom_query "max(checkout_slo_target_percent{namespace=\"$NS_DEMO\"})" \
          | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true)"
  if [[ -z "$slo" || "$slo" == "NaN" ]]; then
    log_error "FAIL: checkout_slo_target_percent has no series"
    return 1
  fi
  rate="$(_fleet_success_rate)"
  if [[ -z "$rate" || "$rate" == "NaN" ]]; then
    log_error "FAIL: the 1m checkout success-rate query is empty or NaN"
    return 1
  fi
  # The rate is a 1m window: right after a fix lands it still holds the failing minute. Wait
  # (FLEET_RATE_WAIT_S, default 0 = strict) for it to clear instead of failing a recovering fleet.
  if ! _rate_meets_slo "$rate" "$slo" && (( ${FLEET_RATE_WAIT_S:-0} > 0 )); then
    SLO_NOW="$slo" wait_for "the 1m success rate to reach ${slo}%" "$FLEET_RATE_WAIT_S" _fleet_rate_recovered || true
    rate="$(_fleet_success_rate)"
  fi
  if ! _rate_meets_slo "$rate" "$slo"; then
    log_error "FAIL: 1m success rate ${rate}% is below the ${slo}% target"
    return 1
  fi
  log_info "fleet disarmed: all Ready pods at ${CONFIG_HEALTHY}, success rate ${rate}% >= ${slo}%"
}

# pods_ready NS : every pod in NS is Ready, except Succeeded pods and the Failed attempts of a Job
# that has since completed (a retried Job keeps its failed first pod until the Job's TTL removes
# it). A Failed pod with no Job owner, or of a Job that has not completed, still fails.
pods_ready() {
  local ns="$1" done_jobs
  done_jobs="$(k get jobs -n "$ns" -o json | jq -c '[.items[]
    | select(any(.status.conditions[]?; .type == "Complete" and .status == "True")) | .metadata.name]')" || return 1
  k get pods -n "$ns" -o json | jq -e --argjson completed "$done_jobs" '
    def retried_job_attempt: .status.phase == "Failed"
      and any(.metadata.ownerReferences[]?; .kind == "Job" and (.name as $n | $completed | index($n)) != null);
    all(.items[] | select(.status.phase != "Succeeded") | select(retried_job_attempt | not);
        any(.status.conditions[]?; .type == "Ready" and .status == "True"))' >/dev/null
}

# ----------------------------------------------------- idempotent helm install
# helm_ensure RELEASE CHART VERSION NAMESPACE VALUES_FILE...
# `helm upgrade --install` writes a new release Secret on every run even when nothing
# changed, which breaks "the second build-all changes nothing". So skip when the release
# is already deployed at this chart version with exactly these values. Several values
# files are passed to helm in order (-f each) and compared as one deep merge, later
# files winning, which is how helm combines them.
helm_ensure() {
  local rel="$1" chart="$2" ver="$3" ns="$4" name have want_vals have_vals f
  shift 4
  (( $# >= 1 )) || die "helm_ensure: at least one values file is required"
  local -a values=("$@") fargs=()
  for f in "${values[@]}"; do
    [[ -r "$f" ]] || die "helm_ensure: values file not readable: $f"
    fargs+=(-f "$f")
  done
  name="${chart##*/}"
  have="$(h list -n "$ns" --filter "^${rel}\$" -o json 2>/dev/null \
          | jq -r '.[0] | select(.status == "deployed") | .chart // empty' || true)"
  if [[ "$have" == "${name}-${ver#v}" ]]; then
    # shellcheck disable=SC2016 # yq variables, not shell ones
    want_vals="$(yq eval-all -o=json '. as $i ireduce ({}; . * ($i // {}))' "${values[@]}" | jq -S -c '.')"
    have_vals="$(h get values "$rel" -n "$ns" -o json 2>/dev/null | jq -S -c '. // {}' || echo '{}')"
    if [[ "$want_vals" == "$have_vals" ]]; then
      log_info "skip: helm release $rel ($name-${ver#v}) unchanged"
      return 0
    fi
  fi
  log_info "helm: installing $rel ($chart $ver) into $ns"
  h upgrade --install "$rel" "$chart" --version "$ver" -n "$ns" --create-namespace \
    "${fargs[@]}" --wait --timeout "${HELM_TIMEOUT:-10m}"
}

# ---------------------------------------------------- stage output (P19)
# The operator scripts run with STAGE=1 on stage: one short line per beat, none longer
# than STAGE_COLS, no git chatter, and no machine lines (cause:, bump:, change_ref:) on
# the terminal. Those go to <main checkout>/.operator/<file> for the e2e scripts instead.
stage_on() { [[ "${STAGE:-0}" == "1" ]]; }

# _stage_fit LINE : print LINE; under STAGE=1, cut to STAGE_COLS, keeping the full line in
# .operator/stage.log when it had to be cut.
_stage_fit() {
  local line="$1" cols="${STAGE_COLS:-30}"
  if stage_on && ((${#line} > cols)); then
    _stage_keep "$line"
    line="${line:0:cols}"
  fi
  printf '%s\n' "$line"
}

_stage_keep() { # TEXT : append to <main checkout>/.operator/stage.log, best effort
  local root
  root="$(main_root 2>/dev/null)" || return 0
  mkdir -p "$root/.operator" 2>/dev/null || return 0
  printf '%s\n' "$1" >>"$root/.operator/stage.log" 2>/dev/null || true
}

# beat TEXT... : one line on stdout. A beat is stage text written on purpose, so under
# STAGE=1 a beat longer than STAGE_COLS is a bug: with STAGE_STRICT=1 (the tests) it fails;
# otherwise it is cut to fit and the full line kept in .operator/stage.log.
beat() {
  local text="$*"
  if stage_on && ((${#text} > ${STAGE_COLS:-30})) && [[ "${STAGE_STRICT:-0}" == "1" ]]; then
    printf 'beat over %s columns: %s\n' "${STAGE_COLS:-30}" "$text" >&2
    return 1
  fi
  _stage_fit "$text"
}

# refuse CODE SHORT FULL... : exit CODE with a reason. Under STAGE=1 the reason is the
# one line "refused: SHORT" (SHORT is at most STAGE_COLS - 9 characters); otherwise
# "error: FULL".
refuse() {
  local code="$1" short="$2"
  shift 2
  if stage_on; then
    _stage_keep "refused: $*"
    _stage_fit "refused: $short" >&2
  else
    log_error "$*"
  fi
  exit "$code"
}

# machine_init NAME : choose where machine lines go. Under STAGE=1 the file
# <main checkout>/.operator/NAME is truncated and used; otherwise they go to stdout.
MACHINE_FILE=""
machine_init() {
  MACHINE_FILE=""
  if stage_on; then
    local dir
    dir="$(main_root)/.operator"
    mkdir -p "$dir"
    MACHINE_FILE="$dir/$1"
    : > "$MACHINE_FILE"
  fi
}

# machine_line KEY VALUE : "KEY: VALUE" on stdout, or in the machine file under STAGE=1.
machine_line() {
  if [[ -n "$MACHINE_FILE" ]]; then
    printf '%s: %s\n' "$1" "$2" >> "$MACHINE_FILE"
  else
    printf '%s: %s\n' "$1" "$2"
  fi
}

# stage_wait DESC TIMEOUT_S CMD... : wait_for, without its stderr chatter under STAGE=1.
# On timeout it still prints one short line (exit 4).
stage_wait() {
  local rc=0
  if ! stage_on; then wait_for "$@"; return; fi
  wait_for "$@" 2>/dev/null || rc=$?
  if (( rc != 0 )); then printf 'timeout: %s\n' "${1:0:21}" >&2; fi
  return "$rc"
}

# quiet CMD... : run CMD with its output held back; print it only when CMD fails.
quiet() {
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if (( rc != 0 )); then printf '%s\n' "$out" >&2; fi
  return "$rc"
}

# new_change_ref : CHG- plus six characters of [A-Z2-7] (Δ28). Never written to Git or the cluster.
new_change_ref() {
  local alphabet=ABCDEFGHIJKLMNOPQRSTUVWXYZ234567 out="CHG-"
  for _ in 1 2 3 4 5 6; do out+="${alphabet:RANDOM%32:1}"; done
  printf '%s' "$out"
}

# ------------------------------------------------- timeline events (Task 3.14, D28)
# The sim the operator scripts post to. Reachable on the host through the kind port mapping.
_sim_url() { printf '%s' "${SIM_HOST_URL:-http://${HOST_BIND:-127.0.0.1}:${PORT_SIM:-30082}}"; }

# _sim_post PATH_AND_QUERY : POST the JSON on stdin. Warns (never fails) when the sim is
# down or answers with an error, so a missing sim can't break an incident script.
_sim_post() {
  local target="$1" err
  if ! err="$(curl -sS --fail --max-time 5 -X POST -H 'Content-Type: application/json' \
        --data-binary @- -o /dev/null "$(_sim_url)$target" 2>&1)"; then
    log_warn "timeline: ${err:-sim unreachable}"
    return 0
  fi
}

# emit_change_event SHA KIND TITLE [CHANGE_REF] : tell the timeline about a change, the way
# a forge or change system would (Δ28): a dev.cdevents.change.merged.0.3.0 (O1) carrying the
# SHA, title, author, time and customData {change_ref, changed_files}. Nothing about the
# diagnosis: no key, from, to or config-version. KIND is for the caller's own log only.
# An empty CHANGE_REF gets a fresh CHG- reference (every real change has one).
emit_change_event() {
  local sha="$1" title="${3:-}" ref="${4:-}" author="" files="" now
  local -a flist=()
  [[ -n "$ref" ]] || ref="$(new_change_ref)"
  if [[ -n "${OPERATOR_DIR:-}" && -d "$OPERATOR_DIR" ]]; then
    author="$(git -C "$OPERATOR_DIR" log -1 --format=%an "$sha" 2>/dev/null || true)"
    files="$(git -C "$OPERATOR_DIR" diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null || true)"
  fi
  [[ -n "$files" ]] && mapfile -t flist <<<"$files"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg sha "$sha" --arg title "$title" --arg ref "$ref" --arg author "${author:-operator}" \
      --arg now "$now" --arg repo "${REPO_SLUG:-argo-multiverse-labs/argoconna26}" \
      --args '{
        context: {specversion: "0.5.1", id: ("chg-" + $sha[0:12]), source: "/argoconna26/operator",
                  type: "dev.cdevents.change.merged.0.3.0", timestamp: $now},
        subject: {id: $sha, content: {repository: {id: $repo}}},
        customData: {title: $title, author: $author, change_ref: $ref, changed_files: $ARGS.positional}
      }' "${flist[@]}" | _sim_post /events
}

# sim_seed RESET REV... : POST /seed. RESET is true or false; with true the sim drops the
# fixture's events and every live event first (keep_live_hours=0, Δ25), so the timeline
# starts the same every time. REV... are real recent checkout commits, oldest first (O6).
sim_seed() {
  local reset="$1"
  shift
  local -a revs=("$@")
  jq -n --args '{checkout_revisions: $ARGS.positional}' "${revs[@]}" \
    | _sim_post "/seed?reset=${reset}&keep_live_hours=0"
}

# ------------------------------------------------- evidence and autonomy (Task 5.5)
# evidence_dir : where scripts save evidence. EVIDENCE_DIR from .env (relative paths are
# under the main checkout), else <main checkout>/.evidence (gitignored).
evidence_dir() {
  local d="${EVIDENCE_DIR:-}"
  [[ -n "$d" ]] || d=".evidence"
  case "$d" in /*) ;; *) d="$(main_root)/$d" ;; esac
  printf '%s' "$d"
}

# tracked_autonomy_level : the level in AUTONOMY_FILE on the tracked branch on GitHub, read
# with gh (so GH_TOKEN, when set, is the credential). Prints nothing and fails if unreadable.
tracked_autonomy_level() {
  local raw
  raw="$(gh api -H 'Accept: application/vnd.github.raw' \
    "repos/${REPO_SLUG}/contents/${AUTONOMY_FILE}?ref=${TRACKED_BRANCH}" 2>/dev/null)" || return 1
  yq -r '.level // ""' <<<"$raw" 2>/dev/null
}
