#!/usr/bin/env bash
# Resets between rehearsals (Task 6.3). Every step is a forward commit or a condition wait;
# nothing reads the time of day, so a reset repeats back to back, any hour.
#
#   scripts/reset.sh 1|2|3|demo
#
# Under the cluster lock, in order:
#   1. op_sync
#   2. rung 3 only: from `suggest` it can't reach `propose` without a review. It opens the
#      `propose` promotion PR, says so, and exits 6 before changing anything else.
#   3. every agent/* PR gets the demo-reset label (so panel 4 starts at 0, O23); open ones are
#      closed with the comment "reset for rehearsal".
#   4. disarm --image <stable tag> (value 2000, stable image and config-version pinned, one
#      forward commit, wait Healthy; O16 two commits when the pods read 200). When Git is
#      already disarmed but Ready pods still read 200 (the old no-op path would wait 150 s and
#      fail), the pods are rolled first with a config-version bump and pinned back.
#   5. autonomy to the rung's starting level (1:suggest 2:suggest 3:propose), by `demote`
#      only: a reset never raises the level.
#   6. the notified.notifications.argoproj.io annotation on the checkout Application is deleted (Δ10).
#   7. promotion PR: rung 2 `propose`, rung 3 `act`, always a fresh one (Δ25); rung 1 and demo
#      close any open one (a leftover from a scene run).
#      rung 1 and demo: seed-history (pre-armed), its cause and change_ref saved to
#      .operator/last-rearm for demo-rung-1. Rungs 2 and 3 stay disarmed (they start with rearm).
#      demo also re-seeds the timeline (reset=true, keep_live_hours=0); per-rung resets leave it alone.
#   8. make bridge-hooks-clear (a killed failure-paths run leaves test hooks), then the bridge pod
#      is deleted (clears its in-memory registry; rehydrate covers open PRs).
#   9. wait for checkout and pricing Healthy; print the elapsed seconds.
#
# Exit codes: 6 rung 3 needs `propose` first, plus those of common.sh and git-ops.sh.
set -euo pipefail
# shellcheck source=scripts/git-ops.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-ops.sh"

PROMOTION_PR="$GIT_OPS_DIR/promotion-pr.sh"
SEED_HISTORY="$GIT_OPS_DIR/seed-history.sh"
BRIDGE_HOOKS="$GIT_OPS_DIR/bridge-hooks.sh"
RESET_LABEL=demo-reset
RESET_COMMENT="reset for rehearsal"
EXIT_NEEDS_PROPOSE=6

# ---------------------------------------------------------------- agent PRs
# label_and_close_agent_prs : label every agent/* PR (any state) demo-reset, close the open ones.
label_and_close_agent_prs() {
  local json n state labelled
  json="$(gh pr list --repo "$REPO_SLUG" --state all --limit 200 \
    --json number,headRefName,state,labels)" || die "could not list the agent PRs"
  while read -r n state labelled; do
    [[ -n "$n" ]] || continue
    if [[ "$labelled" != true ]]; then
      gh api -X POST "repos/${REPO_SLUG}/issues/${n}/labels" -f "labels[]=${RESET_LABEL}" >/dev/null \
        || die "could not label PR $n ${RESET_LABEL}"
      log_info "labelled agent PR $n ${RESET_LABEL}"
    fi
    if [[ "$state" == OPEN ]]; then
      gh pr close "$n" --repo "$REPO_SLUG" --comment "$RESET_COMMENT" >/dev/null \
        || die "could not close agent PR $n"
      log_info "closed agent PR $n"
    fi
  done < <(jq -r --arg l "$RESET_LABEL" '.[] | select(.headRefName | startswith("agent/"))
      | "\(.number) \(.state) \([.labels[]?.name] | index($l) != null)"' <<<"$json")
}

# ------------------------------------------------------------------ disarm
git_at_disarm_targets() {
  [[ "$(config_value_get)" == "$CONFIG_HEALTHY" \
    && "$(image_tag_get)" == "$CHECKOUT_STABLE_TAG" \
    && "$(config_version_get)" == "$CONFIG_VERSION_START" ]]
}

# armed_pod_count : checkout pods whose gauge includes CONFIG_ARMED (0 when Prometheus is silent).
armed_pod_count() {
  local gauge
  gauge="$(_gauge_pods 2>/dev/null || true)"
  awk -v armed="$CONFIG_ARMED" '{n = split($2, v, ","); for (i = 1; i <= n; i++) if (v[i] == armed) {c++; break}}
    END {print c + 0}' <<<"$gauge"
}

_commit_sync_healthy() { # MSG : commit the rollout file, tell the sim, sync, wait Healthy
  local sha
  sha="$(op_commit_push "$1" "$ROLLOUT_FILE")"
  emit_change_event "$sha" disarm "$1" ""
  argo_refresh_and_wait checkout "$sha"
  op_wait_health checkout Healthy
}

# heal_stale_armed_pods : Git is at the disarmed targets but pods started while armed still read
# 200 (the ConfigMap is read at start). Bump config-version so they roll, then pin it back.
heal_stale_armed_pods() {
  git_at_disarm_targets || return 0
  (($(armed_pod_count) > 0)) || return 0
  beat "pods still at $CONFIG_ARMED"
  config_version_bump >/dev/null
  _commit_sync_healthy "chore(demo): roll checkout pods to read the disarmed config"
  op_wait_fleet_disarmed
  # shellcheck disable=SC2154 # _cv_path comes from git-ops.sh
  yaml_set "$ROLLOUT_FILE" "$_cv_path" "$CONFIG_VERSION_START"
  _commit_sync_healthy "chore(demo): pin config-version to $CONFIG_VERSION_START"
  op_wait_fleet_disarmed
  beat "pods rolled"
}

# ---------------------------------------------------------------- autonomy
# lower_autonomy_to LEVEL : demote (a forward commit) until the level is LEVEL. Never raises.
lower_autonomy_to() {
  local want="$1" cur
  cur="$(current_level)"
  while (($(level_index "$cur") > $(level_index "$want"))); do
    "$PROMOTION_PR" demote
    op_sync
    cur="$(current_level)"
  done
}

ensure_promotion_pr() { # LEVEL -> echoes the PR number
  local out
  out="$("$PROMOTION_PR" ensure "$1")" || return 1
  sed -n 's/^pr: *//p' <<<"$out" | head -n1
}

# --------------------------------------------------------------- the bridge
bridge_status_ok() {
  curl -sf --max-time 5 "127.0.0.1:${PORT_BRIDGE}/status" >/dev/null
}

restart_bridge() {
  "$BRIDGE_HOOKS" clear
  k delete pod -n "$NS_AIOPS" -l app=bridge --wait=true >/dev/null
  k rollout status deploy/bridge -n "$NS_AIOPS" --timeout=120s >/dev/null
  wait_for "bridge /status answers" 90 bridge_status_ok
}

# ------------------------------------------------------------------- main
usage() { die "usage: reset.sh 1|2|3|demo"; }

main() {
  local target="${1:-}" start_level pr
  case "$target" in 1 | 2 | 3 | demo) ;; *) usage ;; esac
  (($# == 1)) || usage
  load_env
  require_context
  cluster_lock
  SECONDS=0

  case "$target" in 3) start_level=propose ;; *) start_level=suggest ;; esac

  op_sync
  if [[ "$target" == 3 && "$(current_level)" == suggest ]]; then
    pr="$(ensure_promotion_pr propose)" || die "could not open the propose promotion PR"
    log_error "rung 3 needs propose first: approve and merge PR #${pr}, then run reset-rung-3 again"
    exit "$EXIT_NEEDS_PROPOSE"
  fi

  label_and_close_agent_prs
  heal_stale_armed_pods
  op_disarm --image "$CHECKOUT_STABLE_TAG"
  op_sync
  lower_autonomy_to "$start_level"

  k annotate application checkout -n "$NS_ARGOCD" notified.notifications.argoproj.io- >/dev/null
  case "$target" in
    # STAGE=1: the cause and change_ref go to .operator/last-rearm, where demo-rung-1 reads them.
    1) "$PROMOTION_PR" close-open; STAGE=1 SEED_TIMELINE_RESET=false "$SEED_HISTORY" ;;
    demo) "$PROMOTION_PR" close-open; STAGE=1 SEED_TIMELINE_RESET=true "$SEED_HISTORY" ;;
    2) pr="$(ensure_promotion_pr propose)" || die "could not open the propose promotion PR" ;;
    3) pr="$(ensure_promotion_pr act)" || die "could not open the act promotion PR" ;;
  esac

  restart_bridge
  op_wait_health checkout Healthy
  op_wait_health pricing Healthy
  log_info "reset ${target} done in ${SECONDS}s"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
