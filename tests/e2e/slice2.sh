#!/usr/bin/env bash
# Slice-2 end to end on the real kind cluster: the incident mechanics, with real waits.
#
#   seed-history -> bump (canary aborts) -> fix (Healthy) -> rearm (aborts again)
#   -> naive-revert (green, then the next deploy aborts) -> disarm --image v1.4.1
#
# Run it from the main checkout: tests/e2e/slice2.sh
# It holds the cluster lock for the whole run, and the make targets it calls re-enter it.
# Timings print as one "slice2:" line at the end and are appended to
# $EVIDENCE_DIR/slice-2/runs.tsv (EVIDENCE_DIR from .env, default <main checkout>/.evidence).
#
# Exit codes: 1 an assertion failed, 3 wrong context, 4 a wait timed out, 5 cluster lock held.

set -euo pipefail
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$E2E_DIR/../../scripts/common.sh"

ABORT_WAIT_S="${ABORT_WAIT_S:-180}"
HEALTHY_WAIT_S="${HEALTHY_WAIT_S:-240}"
STABLE_TAG="${CHECKOUT_STABLE_TAG_OVERRIDE:-}"

# ------------------------------------------------------------------ helpers
now() { date +%s; }

step() { printf '\n== %s\n' "$*" >&2; }

fail() { log_error "slice2: $*"; exit 1; }

# Run a make target, echo its output to stderr and the run log, return its stdout.
run_make() {
  local out rc=0
  out="$(make --no-print-directory -C "$ROOT" "$@" 2> >(tee -a "$RUN_LOG" >&2))" || rc=$?
  printf '%s\n' "$out" | tee -a "$RUN_LOG" >&2
  ((rc == 0)) || fail "make $* exited $rc"
  printf '%s\n' "$out"
}

ro_get() { # JSONPATH on the checkout Rollout
  k get rollout checkout -n "$NS_DEMO" -o "jsonpath=$1"
}

app_health() { k get application checkout -n "$NS_ARGOCD" -o jsonpath='{.status.health.status}'; }

# The Rollout has aborted the canary whose hash differs from STABLE.
rollout_aborted_off() { # STABLE_HASH
  local got phase abort cur
  got="$(ro_get '{.status.phase} {.status.abort} {.status.currentPodHash}')"
  read -r phase abort cur <<<"$got"
  [[ "$phase" == Degraded && "$abort" == true && -n "$cur" && "$cur" != "$1" ]]
}

# Fully promoted onto a hash that is neither OLD_A nor OLD_B.
rollout_promoted_past() { # OLD_A OLD_B
  local got phase stable cur
  got="$(ro_get '{.status.phase} {.status.stableRS} {.status.currentPodHash}')"
  read -r phase stable cur <<<"$got"
  [[ "$phase" == Healthy && -n "$cur" && "$stable" == "$cur" && "$cur" != "$1" && "$cur" != "${2:-}" ]]
}

app_health_is() { [[ "$(app_health)" == "$1" ]]; }

# Events on the checkout Rollout with REASON, last seen at or after SINCE (epoch) and at or
# before UNTIL (epoch, optional). Prints "epoch message" lines.
rollout_events() { # REASON SINCE [UNTIL]
  k get events -n "$NS_DEMO" --field-selector "reason=$1,involvedObject.kind=Rollout,involvedObject.name=checkout" -o json \
    | jq -r --argjson since "$2" --argjson until "${3:-9999999999}" '
        .items[]
        | ((.series.lastObservedTime // .lastTimestamp // .eventTime) | sub("\\.[0-9]+"; "") | fromdateiso8601) as $t
        | select($t >= $since and $t <= $until)
        | "\($t) \(.message)"'
}

# The same events from the Rollouts controller's log. client-go's event spam filter
# (per object: a burst of 25, then one every 5 min) drops most of the checkout Rollout's
# events after a few runs, so a missing Event object proves nothing; the controller logs
# every event it records, dropped or not.
rollout_log_events() { # REASON SINCE [UNTIL]
  k logs -n "$NS_ROLLOUTS" "deploy/$ROLLOUTS_RELEASE" --since-time="$(date -u -d "@$2" +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null \
    | grep -F "event_reason=$1 namespace=$NS_DEMO rollout=checkout" \
    | sed -nE 's/^time="([^"]+)".*msg="((\\.|[^"\\])*)".*/\1 \2/p' \
    | while read -r ts msg; do
        t="$(date -u -d "$ts" +%s)"
        ((t >= $2 && t <= ${3:-9999999999})) && printf '%s %s (controller log)\n' "$t" "$msg"
      done || true
}

# Prints the matching events, from the Event API or else from the controller's log.
rollout_event_seen() { # REASON SINCE [UNTIL]
  local out
  out="$(rollout_events "$@")"
  [[ -n "$out" ]] || out="$(rollout_log_events "$@")"
  [[ -n "$out" ]] && printf '%s\n' "$out"
}

prom() { # EXPR -> JSON
  curl -sf --max-time 10 --get --data-urlencode "query=$1" "${PROM_HOST_URL}/api/v1/query"
}

# "pod value" for every checkout pod, the max of the gauge over the last 5 m.
gauge_by_pod() {
  prom "max by (pod) (max_over_time(checkout_config_upstream_timeout_ms{namespace=\"$NS_DEMO\"}[5m]))" \
    | jq -r '.data.result[] | "\(.metric.pod) \(.value[1])"' | sort
}

# Stable pods of HASH created before / after SINCE (epoch), one name per line.
stable_pods() { # HASH SINCE before|after
  k get pods -n "$NS_DEMO" -l "rollouts-pod-template-hash=$1" -o json \
    | jq -r --argjson since "$2" --arg when "$3" '.items[]
        | (.metadata.creationTimestamp | fromdateiso8601) as $c
        | select(if $when == "before" then $c < $since else $c >= $since end)
        | .metadata.name' | sort
}

# Δ1 evidence (a): every canary pod reads ARMED, and every stable pod that was already
# running before T0 reads HEALTHY. (Stable pods that Rollouts starts after T0, when it
# scales the stable ReplicaSet back up on abort, read the armed ConfigMap too: see
# report_new_stable_pods.)
gauge_split_ok() { # CANARY_HASH STABLE_HASH T0
  local g canary stable p v
  g="$(gauge_by_pod)" || return 1
  canary="$(awk -v h="checkout-$1-" 'index($1, h) == 1 {print $2}' <<<"$g" | sort -u)"
  [[ "$canary" == "$CONFIG_ARMED" ]] || return 1
  stable="$(stable_pods "$2" "$3" before)"
  [[ -n "$stable" ]] || return 1
  while read -r p; do
    v="$(awk -v p="$p" '$1 == p {print $2}' <<<"$g")"
    [[ "$v" == "$CONFIG_HEALTHY" ]] || return 1
  done <<<"$stable"
}

# Stable pods started after T0, with the value each one reads. Prints "N armed" on stdout.
report_new_stable_pods() { # STABLE_HASH T0
  local g p v n=0
  g="$(gauge_by_pod)" || true
  while read -r p; do
    [[ -n "$p" ]] || continue
    v="$(awk -v p="$p" '$1 == p {print $2}' <<<"$g")"
    log_info "stable pod started after T0: $p reads ${v:-no series yet}"
    [[ "$v" == "$CONFIG_ARMED" ]] && n=$((n + 1))
  done <<<"$(stable_pods "$1" "$2" after)"
  printf '%s\n' "$n"
}

all_new_stable_pods_scraped() { # STABLE_HASH T0
  local g p
  g="$(gauge_by_pod)" || return 1
  while read -r p; do
    [[ -z "$p" ]] || grep -q "^$p " <<<"$g" || return 1
  done <<<"$(stable_pods "$1" "$2" after)"
}

# ------------------------------------------------------------------ main
main() {
  load_env
  require_context
  ROOT="$(main_root)"
  [[ "$(cd "$E2E_DIR/../.." && pwd -P)" == "$(cd "$ROOT" && pwd -P)" ]] \
    || die "run slice2.sh from the main checkout ($ROOT), not a worktree"
  cluster_lock

  local evdir run_id t_start
  evdir="${EVIDENCE_DIR:-$ROOT/.evidence}/slice-2"
  mkdir -p "$evdir"
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_LOG="$evdir/e2e-$run_id.log"
  : > "$RUN_LOG"
  t_start="$(now)"
  log_info "slice2: run $run_id, log $RUN_LOG"

  step "fresh bridge and sim code (Task 2.4)"
  local d
  for d in bridge:redeploy-bridge cdevents-sim:redeploy-sim; do
    if [[ -f "$ROOT/${d%%:*}/Dockerfile" ]]; then
      run_make "${d#*:}" >/dev/null
      "$ROOT/scripts/ensure-image.sh" --assert-running "${d%%:*}" || fail "${d%%:*} runs a stale image"
    else
      log_info "skip: ${d%%:*} has no Dockerfile on this branch yet"
    fi
  done

  step "seed history (disarm, PR-242, docs)"
  run_make seed-history >/dev/null

  # ---- first incident: bump -> abort
  local stable0 t0 t_bumped t_abort abort_s canary1 stable1 armed_stable
  stable0="$(ro_get '{.status.stableRS}')"
  step "bump (T0)"
  t0="$(now)"
  run_make bump >/dev/null
  t_bumped="$(now)"
  wait_for "checkout Rollout Degraded with abort=true" "$ABORT_WAIT_S" rollout_aborted_off "$stable0"
  t_abort="$(now)"
  abort_s=$((t_abort - t0))
  canary1="$(ro_get '{.status.currentPodHash}')"
  stable1="$(ro_get '{.status.stableRS}')"
  log_info "abort: ${abort_s}s after T0 ($((t_abort - t_bumped))s after the sync), canary $canary1, stable $stable1"
  wait_for "checkout Application Degraded" 60 app_health_is Degraded
  wait_for "a RolloutAborted event since T0" 30 rollout_event_seen RolloutAborted "$t0" \
    || fail "no RolloutAborted event since T0"
  rollout_event_seen RolloutAborted "$t0" | tee -a "$RUN_LOG" >&2
  wait_for "gauge: canary pods at $CONFIG_ARMED, pre-T0 stable pods at $CONFIG_HEALTHY" 60 \
    gauge_split_ok "$canary1" "$stable1" "$t0" || { gauge_by_pod >&2; fail "gauge split not seen"; }
  wait_for "a gauge series for every stable pod started after T0" 60 \
    all_new_stable_pods_scraped "$stable1" "$t0" || true
  armed_stable="$(report_new_stable_pods "$stable1" "$t0" 2> >(tee -a "$RUN_LOG" >&2))"
  gauge_by_pod | grep -E "^checkout-($canary1|$stable1)-" | tee -a "$RUN_LOG" >&2

  # ---- the real fix
  local t_fix fix_s
  step "fix"
  t_fix="$(now)"
  run_make fix >/dev/null
  wait_for "checkout Rollout Healthy on a new revision" "$HEALTHY_WAIT_S" \
    rollout_promoted_past "$stable1" "$canary1"
  fix_s=$(($(now) - t_fix))
  wait_for "checkout Application Healthy" 60 app_health_is Healthy
  log_info "fix -> Healthy: ${fix_s}s"

  # ---- rearm: config 200 as its own revision, then a bump that aborts
  local stable2 t_rearm t_rearmed rearm_abort_s
  stable2="$(ro_get '{.status.stableRS}')"
  step "rearm"
  t_rearm="$(now)"
  run_make rearm >/dev/null
  t_rearmed="$(now)"
  wait_for "checkout Rollout Degraded with abort=true (rearm)" "$ABORT_WAIT_S" rollout_aborted_off "$stable2"
  rearm_abort_s=$(($(now) - t_rearmed))
  wait_for "checkout Application Degraded (rearm)" 60 app_health_is Degraded
  log_info "rearm: aborted ${rearm_abort_s}s after rearm returned ($(($(now) - t_rearm))s after it started)"

  # ---- green but wrong
  local t_rev t_green t_nr_end ts line naive_log green_s naive_abort_s t_bump2=""
  step "naive-revert"
  naive_log="$evdir/naive-$run_id.log"
  t_rev="$(now)"
  t_green=""
  # One timestamped line per beat, so the event window can be checked afterwards.
  if ! make --no-print-directory -C "$ROOT" naive-revert 2>&1 | while IFS= read -r line; do
         printf '%s %s\n' "$(now)" "$line"
       done | tee "$naive_log" | tee -a "$RUN_LOG" >&2; then
    fail "make naive-revert failed"
  fi
  t_nr_end="$(now)"
  while read -r ts line; do
    case "$line" in
      "green: image back to "*) t_green="$ts" ;;
      "pushed: image "*) [[ -n "$t_green" ]] && t_bump2="$ts" ;;
    esac
  done <"$naive_log"
  [[ -n "$t_green" ]] || fail "naive-revert never printed green"
  [[ -n "$t_bump2" ]] || fail "naive-revert never pushed the second bump"
  grep -q ' aborted again: still armed$' "$naive_log" || fail "naive-revert did not end aborted"
  rollout_event_seen SkipSteps "$((t_rev - 1))" "$t_bump2" >/dev/null \
    || fail "no SkipSteps (rollback to stable) event between the revert and the next bump"
  rollout_event_seen SkipSteps "$((t_rev - 1))" "$t_bump2" | tee -a "$RUN_LOG" >&2
  green_s=$((t_green - t_rev))
  naive_abort_s=$((t_nr_end - t_bump2))
  rollout_aborted_off "$(ro_get '{.status.stableRS}')" || fail "Rollout is not Degraded/aborted after naive-revert"
  app_health_is Degraded || fail "checkout Application is not Degraded after naive-revert"
  log_info "naive-revert: green ${green_s}s after start, second bump Degraded ${naive_abort_s}s after its push"

  # ---- back to the start
  local t_dis disarm_s tag
  step "disarm --image v1.4.1"
  t_dis="$(now)"
  run_make disarm IMAGE="${STABLE_TAG:-$CHECKOUT_STABLE_TAG}" >/dev/null
  wait_for "checkout Rollout Healthy (disarmed)" "$HEALTHY_WAIT_S" \
    rollout_promoted_past "" ""
  disarm_s=$(($(now) - t_dis))
  tag="$(k get rollout checkout -n "$NS_DEMO" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  [[ "$tag" == "checkout:${STABLE_TAG:-$CHECKOUT_STABLE_TAG}" ]] || fail "image is $tag after disarm"
  # The 1 m success rate can still hold the aborted canary's errors for a few seconds.
  FLEET_WAIT_S=30 wait_for "fleet disarmed (gauge 2000 on every pod, success rate >= SLO)" 120 \
    check_fleet_disarmed || { FLEET_WAIT_S=5 check_fleet_disarmed || true; fail "fleet is not disarmed"; }

  local total_s=$(($(now) - t_start)) summary
  summary="slice2: run=$run_id abort_s=$abort_s fix_s=$fix_s rearm_abort_s=$rearm_abort_s green_s=$green_s naive_abort_s=$naive_abort_s disarm_s=$disarm_s armed_stable_pods=$armed_stable total_s=$total_s"
  printf '%s\n' "$summary" | tee -a "$RUN_LOG"
  [[ -s "$evdir/runs.tsv" ]] \
    || printf 'run\tabort_s\tfix_s\trearm_abort_s\tgreen_s\tnaive_abort_s\tdisarm_s\tarmed_stable_pods\ttotal_s\n' >"$evdir/runs.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run_id" "$abort_s" "$fix_s" "$rearm_abort_s" \
    "$green_s" "$naive_abort_s" "$disarm_s" "$armed_stable" "$total_s" >>"$evdir/runs.tsv"

  local rc=0
  # Spec §3: the abort lands in "about 30-60 s".
  ((abort_s >= 25 && abort_s <= 60)) || { log_warn "abort ${abort_s}s is outside about 30-60s"; rc=1; }
  ((fix_s <= 75)) || { log_warn "fix -> Healthy ${fix_s}s is over 75s"; rc=1; }
  if ((rc == 0)); then log_info "slice2: PASS"; else log_error "slice2: timing outside the acceptance window"; fi
  return "$rc"
}

main "$@"
