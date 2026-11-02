#!/usr/bin/env bash
# The failure paths draft §5 reacts to, on the real kind cluster and real GitHub (Task 4.6 Step 3).
#
#   start: level propose (a promotion PR merged with admin bypass if it is lower, a demote if higher)
#   1 refusal   CONFIDENCE_THRESHOLD above 1 -> rearm -> a refusal comment on the cause commit
#               (reason low_confidence), no PR, the guardrail counter +1, "▸ refused: low_confidence"
#   2 timeout   TEST_HOLMES_TIMEOUT_S=1 -> rearm -> the handoff comment on the synced revision,
#               exactly the fixed text (no model text), < 120 s after Degraded, /status holmes_failed
#   3 reject    rearm -> the fix PR -> closed unmerged by a human -> rejected count +1 within 60 s;
#   + demote    make demote -> level suggest on the tracked branch -> disarm, rearm -> the bridge
#               logs "▸ autonomy: suggest" and comments on the cause commit, no PR
#
# The test hooks live in the optional Secret bridge-env (Argo CD self-heals the Deployment, so its
# env can't be edited). Each case deletes the Secret and the bridge pod again, then `make fix`,
# and waits Healthy. The run ends at autonomy suggest, disarmed at CHECKOUT_STABLE_TAG.
#
# Usage, from the main checkout: tests/e2e/failure-paths.sh [refusal|timeout|reject ...]
# (default: all three, in that order). Results go to $EVIDENCE_DIR/slice-4/failure-paths-<run>.log.
# Exit codes: 1 an assertion failed, 3 wrong context, 4 a wait timed out, 5 cluster lock held.

set -euo pipefail
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git-ops.sh
. "$E2E_DIR/../../scripts/git-ops.sh"
# shellcheck source=tests/e2e/assert.sh
. "$E2E_DIR/assert.sh"

DEGRADED_WAIT_S="${DEGRADED_WAIT_S:-180}"
HEALTHY_WAIT_S="${HEALTHY_WAIT_S:-240}"
COMMENT_WAIT_S="${COMMENT_WAIT_S:-300}"
HANDOFF_MAX_S=120
REJECT_COUNT_MAX_S=60
TIMEOUT_TEXT='Investigation did not finish in 1 s; a human should take this one.'

now() { date +%s; }
step() { printf '\n== %s\n' "$*" >&2; }
fail() { log_error "failure-paths: $*"; exit 1; }

run_make() { # TARGET... : output to stderr and the run log, stdout returned
  local out rc=0
  out="$(make --no-print-directory -C "$ROOT" "$@" 2> >(tee -a "$RUN_LOG" >&2))" || rc=$?
  printf '%s\n' "$out" | tee -a "$RUN_LOG" >&2
  ((rc == 0)) || fail "make $* exited $rc"
  printf '%s\n' "$out"
}

run_promo() {
  local out rc=0
  out="$("$ROOT/scripts/promotion-pr.sh" "$@" 2> >(tee -a "$RUN_LOG" >&2))" || rc=$?
  printf '%s\n' "$out" | tee -a "$RUN_LOG" >&2
  ((rc == 0)) || fail "promotion-pr.sh $* exited $rc"
  printf '%s\n' "$out"
}

machine() { sed -n "s/^$1: //p" <<<"$2" | tail -n1; } # KEY TEXT
commit_time() { _og show -s --format=%ct "$1"; }
record() { printf '%s\n' "$*" | tee -a "$RUN_LOG" >&2; }

delete_remote_branch() {
  if gh api -X DELETE "repos/$REPO_SLUG/git/refs/heads/$1" >/dev/null 2>&1; then
    log_info "failure-paths: deleted branch $1"
  else
    log_warn "failure-paths: could not delete branch $1"
  fi
}

close_open_agent_prs() { # LABEL|"" : close every open agent PR for checkout, delete its branch
  local n branch
  for n in $(open_agent_prs checkout); do
    branch="$(gh pr view "$n" --repo "$REPO_SLUG" --json headRefName --jq .headRefName)"
    # REST, not `gh pr edit --add-label`: that fails on the classic-projects GraphQL field.
    [[ -z "${1:-}" ]] ||
      gh api -X POST "repos/$REPO_SLUG/issues/$n/labels" -f "labels[]=$1" >/dev/null
    gh pr close "$n" --repo "$REPO_SLUG" --comment "closed by tests/e2e/failure-paths.sh" >/dev/null
    log_warn "failure-paths: closed agent PR $n"
    delete_remote_branch "$branch"
  done
}

# ---------------------------------------------------------------- the bridge's test hooks
restart_bridge() {
  k delete pod -n "$NS_AIOPS" -l app=bridge --wait=true >/dev/null
  k rollout status deploy/bridge -n "$NS_AIOPS" --timeout=120s >/dev/null
  wait_for "bridge /status: GitHub token and HolmesGPT ok" 90 bridge_ready
}

bridge_ready() { bridge_status | jq -e '.github_token_ok and .holmes_reachable' >/dev/null; }

set_bridge_env() { # KEY=VALUE... : the optional Secret bridge-env, then a fresh bridge pod
  local args=() kv
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  k create secret generic bridge-env -n "$NS_AIOPS" "${args[@]}" --dry-run=client -o yaml | k apply -f - >/dev/null
  BRIDGE_ENV_SET=1
  restart_bridge
  log_info "failure-paths: bridge-env set: ${*%%=*}"
}

clear_bridge_env() {
  k delete secret bridge-env -n "$NS_AIOPS" --ignore-not-found >/dev/null
  restart_bridge
  BRIDGE_ENV_SET=0
  log_info "failure-paths: bridge-env removed"
}

# ---------------------------------------------------------------- incident plumbing
REARM_CAUSE="" REARM_BUMP="" REARM_T0=""
rearm() {
  local out
  out="$(run_make rearm)"
  REARM_CAUSE="$(machine cause "$out")"
  REARM_BUMP="$(machine bump "$out")"
  [[ "$REARM_CAUSE" =~ ^[0-9a-f]{40}$ && "$REARM_BUMP" =~ ^[0-9a-f]{40}$ ]] || fail "rearm did not print cause and bump"
  REARM_T0="$(commit_time "$REARM_BUMP")"
  log_info "failure-paths: cause ${REARM_CAUSE:0:7}, bump ${REARM_BUMP:0:7}"
}

wait_degraded() { wait_for "checkout Application Degraded" "$DEGRADED_WAIT_S" app_health_is checkout Degraded; }

fix_and_wait_healthy() {
  run_make fix >/dev/null
  wait_for "checkout Application Healthy" "$HEALTHY_WAIT_S" app_health_is checkout Healthy
}

# the_comment SHA T0 : wait for exactly one bot comment on SHA after T0; sets C_BODY, C_URL, C_CREATED
the_comment() {
  wait_for "a comment from $BOT_LOGIN on ${1:0:7} after T0" "$COMMENT_WAIT_S" have_bot_commit_comment "$1" "$2" \
    || { bridge_status >&2; fail "no comment on ${1:0:7} within ${COMMENT_WAIT_S}s"; }
  local c n
  c="$(bot_commit_comments "$1" "$2")"
  n="$(grep -c . <<<"$c")"
  ((n == 1)) || fail "$n comments from $BOT_LOGIN on ${1:0:7} after T0, expected one"
  C_BODY="$(jq -r .body <<<"$c")"
  C_URL="$(jq -r .url <<<"$c")"
  C_CREATED="$(jq -r .created <<<"$c")"
  printf '%s\n' "--- comment $C_URL" "$C_BODY" "---" | tee -a "$RUN_LOG" >&2
}

no_agent_pr_since() { # T0
  [[ -z "$(agent_prs_since "$1" checkout)" ]] || fail "an agent PR was opened after T0: $(agent_prs_since "$1" checkout)"
}

stage_line_seen() { # SINCE LINE
  wait_for "stage line '$2'" 30 bridge_has_stage_line "$1" "$2" || {
    bridge_stage_lines "$1" >&2
    fail "the bridge did not log '$2'"
  }
  record "stage: $2"
}

# ---------------------------------------------------------------- start state
ensure_propose() {
  op_sync
  local level out pr branch
  level="$(yaml_get "$AUTONOMY_FILE" .level)"
  case "$level" in
    propose) return 0 ;;
    act) run_promo demote >/dev/null ;;
    suggest)
      out="$(run_promo ensure propose)"
      pr="$(machine pr "$out")"
      branch="$(machine branch "$out")"
      run_promo merge "$pr" --admin >/dev/null
      delete_remote_branch "$branch"
      run_promo record-approval "$pr" >/dev/null
      ;;
    *) fail "unknown level '$level'" ;;
  esac
  wait_for "$AUTONOMY_FILE@$TRACKED_BRANCH is propose" 60 tracked_level_is propose
}

# ---------------------------------------------------------------- the cases
case_refusal() {
  step "1 refusal: CONFIDENCE_THRESHOLD=1.01"
  set_bridge_env CONFIDENCE_THRESHOLD=1.01
  local series='aiops_guardrail_executions_total{reason="low_confidence"}' before t_deg
  before="$(bridge_metric "$series")"
  run_make disarm >/dev/null
  rearm
  wait_degraded
  t_deg="$(now)"
  the_comment "$REARM_CAUSE" "$REARM_T0"
  grep -q '^## Agent refused' <<<"$C_BODY" || fail "the comment on the cause is not a refusal"
  grep -qE '^- low_confidence: ' <<<"$C_BODY" || fail "the refusal does not give the reason low_confidence"
  no_agent_pr_since "$REARM_T0"
  wait_for "$series = before + 1" 30 bridge_metric_is "$series" "$(awk -v a="$before" 'BEGIN {print a + 1}')" \
    || fail "$series is $(bridge_metric "$series"), expected $before + 1"
  stage_line_seen "$REARM_T0" "▸ refused: low_confidence"
  record "refusal: comment $C_URL, $((C_CREATED - t_deg)) s after Degraded, $series $before -> $(bridge_metric "$series")"
  clear_bridge_env
  fix_and_wait_healthy
}

case_timeout() {
  step "2 HolmesGPT timeout: TEST_HOLMES_TIMEOUT_S=1"
  set_bridge_env TEST_HOLMES_TIMEOUT_S=1
  local t_deg
  rearm
  wait_degraded
  t_deg="$(now)"
  # The handoff goes on the revision Argo synced (the bump), not on a cause nobody verified.
  the_comment "$REARM_BUMP" "$REARM_T0"
  [[ "$C_BODY" == "$TIMEOUT_TEXT" ]] || fail "the handoff is not exactly the fixed text: $C_BODY"
  ((C_CREATED - t_deg < HANDOFF_MAX_S)) || fail "the handoff came $((C_CREATED - t_deg)) s after Degraded"
  bridge_status | jq -e '.last_incident.holmes_failed == true' >/dev/null \
    || { bridge_status >&2; fail "/status last_incident.holmes_failed is not true"; }
  no_agent_pr_since "$REARM_T0"
  stage_line_seen "$REARM_T0" "▸ holmes: timed out"
  record "timeout: handoff $C_URL, $((C_CREATED - t_deg)) s after Degraded, /status holmes_failed true"
  clear_bridge_env
  fix_and_wait_healthy
}

case_reject_and_demote() {
  step "3 reject the fix PR, then demote"
  tracked_level_is propose || fail "case 3 needs level propose"
  local series='aiops_fix_prs_total{outcome="rejected"}' before pr branch t_close t_counted
  before="$(rejected_fix_prs_on_github checkout)"
  wait_for "the reconciler's rejected count equals GitHub's ($before)" 90 bridge_metric_is "$series" "$before" \
    || fail "$series is $(bridge_metric "$series"), GitHub says $before"
  rearm
  wait_degraded
  wait_for "a fix PR from $BOT_LOGIN after T0" 300 have_agent_pr_since "$REARM_T0" checkout || fail "no fix PR"
  pr="$(agent_prs_since "$REARM_T0" checkout | jq -r .number | head -n1)"
  branch="$(gh pr view "$pr" --repo "$REPO_SLUG" --json headRefName --jq .headRefName)"
  gh pr close "$pr" --repo "$REPO_SLUG" --comment "Rejected: not the fix we want (failure-paths test)." >/dev/null
  t_close="$(now)"
  wait_for "$series = $((before + 1))" "$REJECT_COUNT_MAX_S" bridge_metric_is "$series" "$((before + 1))" \
    || fail "$series did not reach $((before + 1)) within ${REJECT_COUNT_MAX_S}s"
  t_counted="$(now)"
  delete_remote_branch "$branch"
  record "reject: PR $pr closed unmerged, $series $before -> $((before + 1)) in $((t_counted - t_close)) s"

  run_make demote >/dev/null
  wait_for "$AUTONOMY_FILE@$TRACKED_BRANCH is suggest" 60 tracked_level_is suggest || fail "the level is not suggest"
  record "demote: $AUTONOMY_FILE@$TRACKED_BRANCH is suggest"
  run_make disarm >/dev/null
  rearm
  wait_degraded
  the_comment "$REARM_CAUSE" "$REARM_T0"
  grep -q '^## Root cause' <<<"$C_BODY" || fail "the comment at suggest is not an RCA"
  no_agent_pr_since "$REARM_T0"
  stage_line_seen "$REARM_T0" "▸ autonomy: suggest"
  stage_line_seen "$REARM_T0" "▸ suggest: commented"
  record "after demote: RCA comment $C_URL on the cause, no PR"
  fix_and_wait_healthy
}

# ---------------------------------------------------------------- main
on_exit() {
  local rc=$?
  trap - EXIT
  if ((rc != 0)) && [[ -n "${RUN_LOG:-}" ]]; then
    log_warn "failure-paths: failed (exit $rc); restoring the bridge and disarming"
    if [[ "${BRIDGE_ENV_SET:-0}" == 1 ]]; then (clear_bridge_env) || log_error "could not remove bridge-env"; fi
    (close_open_agent_prs demo-reset) || true
    (run_make disarm IMAGE="$CHECKOUT_STABLE_TAG" >/dev/null) \
      || log_error "failure-paths: the cleanup disarm failed too; run make disarm IMAGE=$CHECKOUT_STABLE_TAG"
  fi
  exit "$rc"
}

main() {
  local cases=("$@") c
  ((${#cases[@]})) || cases=(refusal timeout reject)
  for c in "${cases[@]}"; do
    case "$c" in refusal | timeout | reject) ;; *) die "usage: failure-paths.sh [refusal|timeout|reject ...]" ;; esac
  done
  load_env
  require_context
  ROOT="$(main_root)"
  [[ "$(cd "$E2E_DIR/../.." && pwd -P)" == "$(cd "$ROOT" && pwd -P)" ]] \
    || die "run failure-paths.sh from the main checkout ($ROOT), not a worktree"
  cluster_lock
  trap on_exit EXIT

  local evdir run_id
  evdir="${EVIDENCE_DIR:-$ROOT/.evidence}/slice-4"
  mkdir -p "$evdir"
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_LOG="$evdir/failure-paths-$run_id.log"
  : >"$RUN_LOG"
  log_info "failure-paths: run $run_id (${cases[*]}), log $RUN_LOG"

  step "start state: fresh bridge, no bridge-env, no open agent PR, level propose"
  "$ROOT/scripts/ensure-image.sh" --assert-running bridge || fail "bridge runs a stale image"
  if k get secret bridge-env -n "$NS_AIOPS" >/dev/null 2>&1; then clear_bridge_env; fi
  close_open_agent_prs demo-reset
  ensure_propose

  for c in "${cases[@]}"; do
    case "$c" in
      refusal) case_refusal ;;
      timeout) case_timeout ;;
      reject) case_reject_and_demote ;;
    esac
  done

  step "finish: disarm --image $CHECKOUT_STABLE_TAG"
  run_make disarm IMAGE="$CHECKOUT_STABLE_TAG" >/dev/null
  wait_for "every Application Synced and Healthy" 180 all_apps_synced_healthy
  record "failure-paths: PASS (${cases[*]}), level $(tracked_file "$AUTONOMY_FILE" | yq -r .level)"
}

main "$@"
