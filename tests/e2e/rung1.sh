#!/usr/bin/env bash
# Rung 1 (suggest) end to end on the real kind cluster, with the real model.
#
#   redeploy bridge and sim -> autonomy is suggest -> disarm --image v1.4.1
#   -> seed-history + bump  (--seed, the first run)   or   rearm (--rearm, later runs)
#   -> Degraded -> the bridge's RCA comment on the cause commit (or its PR) -> fix -> Healthy
#
# What it asserts on the one new comment from BOT_LOGIN after T0:
#   - it is an RCA ("## Root cause"), not a refusal, a PII block or a handoff
#   - it names the cause (short or full SHA) and has a "Cause: <full sha>" line
#   - it has 200 and 2000 as separate tokens
#   - its "- Timeline:" line cites the cause's change_ref, which only the operator's change
#     event on the timeline carries (Δ28), so citing it proves the timeline was read
# plus: the bridge logged a timeline tool call, every checkout pod started before the cause
# commit reads 2000 and every pod started after it reads 200 (by start time, O15), and after
# the fix the incident on /incidents is resolved.
#
# T0 is the bump commit's time (the deploy that gets aborted). Timings go to stdout as one
# "rung1:" line and to $EVIDENCE_DIR/slice-3/rung1-runs.tsv (EVIDENCE_DIR from .env or the
# caller, default <main checkout>/.evidence).
#
# Usage, from the main checkout: tests/e2e/rung1.sh [--seed|--rearm]
# Exit codes: 1 an assertion failed, 3 wrong context, 4 a wait timed out, 5 cluster lock held.

set -euo pipefail
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git-ops.sh
. "$E2E_DIR/../../scripts/git-ops.sh"

COMMENT_WAIT_S="${COMMENT_WAIT_S:-300}"
DEGRADED_WAIT_S="${DEGRADED_WAIT_S:-180}"
HEALTHY_WAIT_S="${HEALTHY_WAIT_S:-240}"

now() { date +%s; }
step() { printf '\n== %s\n' "$*" >&2; }
fail() { log_error "rung1: $*"; exit 1; }

# Run a make target; its output goes to stderr and the run log, its stdout is returned.
run_make() {
  local out rc=0
  out="$(make --no-print-directory -C "$ROOT" "$@" 2> >(tee -a "$RUN_LOG" >&2))" || rc=$?
  printf '%s\n' "$out" | tee -a "$RUN_LOG" >&2
  ((rc == 0)) || fail "make $* exited $rc"
  printf '%s\n' "$out"
}

machine() { # KEY TEXT : the value of a "KEY: value" machine line in TEXT
  sed -n "s/^$1: //p" <<<"$2" | tail -n1
}

app_health_is() { [[ "$(k get application checkout -n "$NS_ARGOCD" -o jsonpath='{.status.health.status}')" == "$1" ]]; }

commit_time() { _og show -s --format=%ct "$1"; }

# ---------------------------------------------------------------- comments
# Every comment from BOT_LOGIN created at or after T0 on the cause commit and on its PRs,
# as JSON lines {created, url, body}.
bot_comments() { # SHA T0
  local sha="$1" t0="$2" prs pr
  {
    gh api "repos/$REPO_SLUG/commits/$sha/comments" --paginate --jq '.[]'
    prs="$(gh api "repos/$REPO_SLUG/commits/$sha/pulls" --jq '.[].number' 2>/dev/null || true)"
    for pr in $prs; do
      gh api "repos/$REPO_SLUG/issues/$pr/comments" --paginate --jq '.[]'
    done
  } | jq -c --arg bot "$BOT_LOGIN" --argjson t0 "$t0" '
      select(.user.login == $bot)
      | (.created_at | fromdateiso8601) as $c
      | select($c >= $t0)
      | {created: $c, url: .html_url, body: .body}'
}

have_bot_comment() { [[ -n "$(bot_comments "$1" "$2")" ]]; }

assert_rca_comment() { # BODY EXPECTED EXPECTED_REF
  local body="$1" sha="$2" ref="$3" timeline
  grep -q '^## Root cause' <<<"$body" || fail "the comment is not an RCA (no '## Root cause')"
  if grep -qE '^## Agent (refused|output blocked)' <<<"$body"; then fail "the comment is a refusal or a PII block"; fi
  if grep -q 'a human should take this one' <<<"$body"; then fail "the comment is a handoff"; fi
  grep -qE "(^|[^0-9a-f])(${sha:0:7}|$sha)" <<<"$body" || fail "the comment does not name the cause ${sha:0:7}"
  grep -qE "^Cause: $sha( |\$)" <<<"$body" || fail "no 'Cause: $sha' line"
  grep -qE '(^|[^0-9])200([^0-9]|$)' <<<"$body" || fail "no 200 token in the comment"
  grep -qE '(^|[^0-9])2000([^0-9]|$)' <<<"$body" || fail "no 2000 token in the comment"
  timeline="$(grep -E '^- Timeline:' <<<"$body" || true)"
  [[ -n "$timeline" ]] || fail "no '- Timeline:' line"
  grep -qF "$ref" <<<"$timeline" || fail "the Timeline line does not cite $ref: $timeline"
}

# ---------------------------------------------------------------- pods by start time (O15)
gauge_by_pod() {
  curl -sf --max-time 10 --get \
    --data-urlencode "query=max by (pod) (max_over_time(checkout_config_upstream_timeout_ms{namespace=\"$NS_DEMO\"}[5m]))" \
    "${PROM_HOST_URL}/api/v1/query" | jq -r '.data.result[] | "\(.metric.pod) \(.value[1])"' | sort
}

# Every live checkout pod started before T_CAUSE reads 2000, every one started after it 200,
# and at least one of each exists.
pods_split_by_start() { # T_CAUSE
  local g pods name created v pre=0 post=0
  g="$(gauge_by_pod)" || return 1
  pods="$(k get pods -n "$NS_DEMO" -l rollouts-pod-template-hash -o json \
    | jq -r '.items[] | select(.metadata.deletionTimestamp == null)
             | "\(.metadata.name) \(.metadata.creationTimestamp | fromdateiso8601)"')" || return 1
  while read -r name created; do
    [[ -n "$name" ]] || continue
    v="$(awk -v p="$name" '$1 == p {print $2}' <<<"$g")"
    if ((created < $1)); then
      [[ "$v" == "$CONFIG_HEALTHY" ]] || return 1
      pre=$((pre + 1))
    else
      [[ "$v" == "$CONFIG_ARMED" ]] || return 1
      post=$((post + 1))
    fi
  done <<<"$pods"
  ((pre > 0 && post > 0))
}

# ---------------------------------------------------------------- incidents
latest_incident_resolved() { # BUMP_SHA
  curl -sf --max-time 5 "$(_sim_url)/incidents?app=checkout" \
    | jq -e --arg rev "$1" '[.[] | select(.revision == $rev)] | max_by(.detected_at) | .resolved_at != null' >/dev/null
}

# ---------------------------------------------------------------- start state
ensure_suggest() {
  op_sync
  local level
  level="$(yaml_get "$AUTONOMY_FILE" .level)"
  [[ "$level" == suggest ]] && return 0
  log_warn "rung1: autonomy is '$level' on $TRACKED_BRANCH; lowering it to suggest"
  yaml_set "$AUTONOMY_FILE" .level suggest
  op_commit_push "chore(demo): autonomy back to suggest for rung 1" "$AUTONOMY_FILE" >/dev/null
}

disarm_to_stable() {
  run_make disarm IMAGE="$CHECKOUT_STABLE_TAG" >/dev/null
}

on_exit() {
  local rc=$?
  trap - EXIT
  if ((rc != 0)) && [[ -n "${RUN_LOG:-}" ]] && [[ "${RUNG1_NO_CLEANUP:-0}" != "1" ]]; then
    log_warn "rung1: failed (exit $rc); disarming to $CHECKOUT_STABLE_TAG"
    (disarm_to_stable) || log_error "rung1: the cleanup disarm failed too; run make disarm IMAGE=$CHECKOUT_STABLE_TAG"
  fi
  exit "$rc"
}

main() {
  local mode="${1:---seed}"
  case "$mode" in --seed | --rearm) ;; *) die "usage: rung1.sh [--seed|--rearm]" ;; esac
  load_env
  require_context
  ROOT="$(main_root)"
  [[ "$(cd "$E2E_DIR/../.." && pwd -P)" == "$(cd "$ROOT" && pwd -P)" ]] \
    || die "run rung1.sh from the main checkout ($ROOT), not a worktree"
  cluster_lock
  trap on_exit EXIT

  local evdir run_id
  evdir="${EVIDENCE_DIR:-$ROOT/.evidence}/slice-3"
  mkdir -p "$evdir"
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_LOG="$evdir/rung1-$run_id.log"
  : >"$RUN_LOG"
  log_info "rung1: run $run_id ($mode), log $RUN_LOG"

  step "fresh bridge and sim code (Task 2.4)"
  run_make redeploy-bridge redeploy-sim >/dev/null
  "$ROOT/scripts/ensure-image.sh" --assert-running bridge || fail "bridge runs a stale image"
  "$ROOT/scripts/ensure-image.sh" --assert-running cdevents-sim || fail "cdevents-sim runs a stale image"
  curl -sf "127.0.0.1:${PORT_BRIDGE}/status" | jq -e '.dry_forge == false' >/dev/null \
    || fail "the bridge runs with DRY_FORGE on; rung 1 needs real writes"

  step "autonomy is suggest on $TRACKED_BRANCH"
  ensure_suggest

  step "start state: disarm --image $CHECKOUT_STABLE_TAG"
  disarm_to_stable

  local out expected expected_ref bump t0 t_cause
  if [[ "$mode" == --seed ]]; then
    step "seed history (PR-242)"
    out="$(run_make seed-history)"
    expected="$(machine cause "$out")"
    expected_ref="$(machine change_ref "$out")"
    step "bump (T0)"
    out="$(run_make bump)"
    bump="$(machine bump "$out")"
  else
    step "rearm (cause, then the bump: T0)"
    out="$(run_make rearm)"
    expected="$(machine cause "$out")"
    expected_ref="$(machine change_ref "$out")"
    bump="$(machine bump "$out")"
  fi
  [[ "$expected" =~ ^[0-9a-f]{40}$ ]] || fail "no cause SHA printed"
  [[ "$expected_ref" =~ ^CHG-[A-Z2-7]{6}$ ]] || fail "no change_ref printed"
  [[ "$bump" =~ ^[0-9a-f]{40}$ ]] || fail "no bump SHA printed"
  t0="$(commit_time "$bump")"
  t_cause="$(commit_time "$expected")"
  log_info "rung1: cause ${expected:0:7} ($expected_ref), bump ${bump:0:7}, T0 $t0"

  step "wait Degraded"
  wait_for "checkout Application Degraded" "$DEGRADED_WAIT_S" app_health_is Degraded
  local t_deg
  t_deg="$(now)"

  step "wait for the agent's comment on ${expected:0:7}"
  wait_for "a comment from $BOT_LOGIN on the cause after T0" "$COMMENT_WAIT_S" have_bot_comment "$expected" "$t0" \
    || { curl -s "127.0.0.1:${PORT_BRIDGE}/status" >&2; fail "no comment within ${COMMENT_WAIT_S}s"; }
  local comments n body url t_comment
  comments="$(bot_comments "$expected" "$t0")"
  n="$(grep -c . <<<"$comments")"
  ((n == 1)) || fail "$n comments from $BOT_LOGIN after T0, expected exactly one"
  t_comment="$(jq -r .created <<<"$comments")"
  url="$(jq -r .url <<<"$comments")"
  body="$(jq -r .body <<<"$comments")"
  printf '%s\n' "--- comment $url" "$body" "---" | tee -a "$RUN_LOG" >&2
  assert_rca_comment "$body" "$expected" "$expected_ref"

  step "bridge logged a timeline tool call"
  k logs -n "$NS_AIOPS" deploy/bridge --since-time="$(date -u -d "@$t0" +%Y-%m-%dT%H:%M:%SZ)" \
    | tee -a "$RUN_LOG" | grep -qE '▸ holmes: GET /(timeline|incidents)' \
    || fail "no cdevents-timeline tool call in the bridge log since T0"

  step "pods by start time (O15)"
  wait_for "pods started before the cause read $CONFIG_HEALTHY, after it $CONFIG_ARMED" 60 \
    pods_split_by_start "$t_cause" || { gauge_by_pod >&2; fail "pod values do not split by start time"; }

  step "fix"
  run_make fix >/dev/null
  wait_for "checkout Application Healthy" "$HEALTHY_WAIT_S" app_health_is Healthy
  wait_for "the incident for ${bump:0:7} resolved on /incidents" 60 latest_incident_resolved "$bump" \
    || fail "the incident is not resolved on /incidents"
  n="$(bot_comments "$expected" "$t0" | grep -c . || true)"
  ((n == 1)) || fail "$n comments from $BOT_LOGIN after the fix, expected still one"

  local t0_comment=$((t_comment - t0)) deg_comment=$((t_comment - t_deg)) summary
  summary="rung1: run=$run_id mode=${mode#--} cause=${expected:0:7} change_ref=$expected_ref t0_to_degraded_s=$((t_deg - t0)) t0_to_comment_s=$t0_comment degraded_to_comment_s=$deg_comment comment=$url"
  printf '%s\n' "$summary" | tee -a "$RUN_LOG"
  [[ -s "$evdir/rung1-runs.tsv" ]] \
    || printf 'run\tmode\tcause\tchange_ref\tt0_to_degraded_s\tt0_to_comment_s\tdegraded_to_comment_s\tcomment\n' >"$evdir/rung1-runs.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run_id" "${mode#--}" "$expected" "$expected_ref" \
    "$((t_deg - t0))" "$t0_comment" "$deg_comment" "$url" >>"$evdir/rung1-runs.tsv"

  ((t0_comment <= 180)) || fail "T0 -> comment ${t0_comment}s is over 180s (spec §8)"
  ((deg_comment < 120)) || fail "Degraded -> comment ${deg_comment}s is 120s or more"
  log_info "rung1: PASS"
}

main "$@"
