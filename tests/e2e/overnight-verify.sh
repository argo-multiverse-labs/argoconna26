#!/usr/bin/env bash
# Check one rung-3 run after the fact, inside a fixed run window [SINCE, UNTIL] (Task 5.6 Step 3, P26).
#
#   tests/e2e/overnight-verify.sh SINCE=<epoch> UNTIL=<epoch> [PR=<n>]
#   tests/e2e/overnight-verify.sh --window <file>          (a file a full PASS wrote earlier)
#
# SINCE is the run's RUN_TS (.operator/last-run, written by make night) or a timer's AT; UNTIL is any
# moment after the run, taken before any reset. Every check reads only inside the window, so later
# resets, rungs and operator commits cannot change the result:
#
#   unit       the job unit argoconna26-rearm started within SINCE + 60 s and finished successfully
#              (the user journal, not the unit's last-run properties)
#   journal    the unit's output in the window has a "cause:" and a "bump:" SHA
#   commits    the only operator commits on the tracked branch with committer dates in the window
#              are that pair (cause, then bump), and the cause carries a Demo-Rearm: trailer
#   pr         exactly one PR from BOT_LOGIN on agent/checkout-* opened in the window (or PR=)
#   merger     mergedBy is the bot, or the PR has an autoMergeRequest
#   merged     merged inside the window
#   reviews    no reviews (no human acted)
#   check      policy-check (GitHub Actions) concluded success on the PR's head SHA, and its log
#              shows the auto-fix conftest step ran (not skipped)
#   metric     aiops_policy_checks_total{result="pass"} is at least one higher at UNTIL than at
#              SINCE (Prometheus, at those two times)
#   deployed   the merge SHA is in the checkout Application's .status.history, deployedAt in the window
#   incident   /incidents?app=checkout has the run's incident (the bump) with resolved_at in the window
#
# On a full PASS it writes the window file $(MAIN_ROOT)/.operator/run-<SINCE> (SINCE, UNTIL, PR,
# MERGE_SHA) and saves its output under $EVIDENCE_DIR/slice-5/overnight-verify-<SINCE>-<now>.txt.
# Exit 0 on PASS, 1 on any FAIL, 2 on usage.
set -euo pipefail
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$E2E_DIR/../../scripts/common.sh"

UNIT=argoconna26-rearm.service
UNIT_START_MAX_S="${UNIT_START_MAX_S:-60}"
SINCE="" UNTIL="" PR="" MERGE_SHA="" CAUSE="" BUMP=""
FAILS=0
OUT=""

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
pass() { say "PASS $1: $2"; }
failc() { say "FAIL $1: $2"; FAILS=$((FAILS + 1)); }

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
in_window() { (($1 >= SINCE && $1 <= UNTIL)); } # EPOCH
epoch_of() { date -d "$1" +%s; }                  # ISO -> epoch

parse_args() {
  local a
  if [[ "${1:-}" == --window ]]; then
    [[ -f "${2:-}" ]] || { log_error "usage: overnight-verify.sh --window <file>"; exit 2; }
    SINCE="$(sed -n 's/^SINCE=//p' "$2")"
    UNTIL="$(sed -n 's/^UNTIL=//p' "$2")"
    PR="$(sed -n 's/^PR=//p' "$2")"
    shift 2
  fi
  for a in "$@"; do
    case "$a" in
      SINCE=*) SINCE="${a#SINCE=}" ;;
      UNTIL=*) UNTIL="${a#UNTIL=}" ;;
      PR=*) PR="${a#PR=}" ;;
      *) log_error "usage: overnight-verify.sh SINCE=<epoch> UNTIL=<epoch> [PR=<n>] | --window <file>"; exit 2 ;;
    esac
  done
  [[ "$SINCE" =~ ^[0-9]+$ && "$UNTIL" =~ ^[0-9]+$ ]] || { log_error "SINCE and UNTIL must be epoch seconds"; exit 2; }
  ((UNTIL > SINCE)) || { log_error "UNTIL must be after SINCE"; exit 2; }
  [[ -z "$PR" || "$PR" =~ ^[0-9]+$ ]] || { log_error "PR must be a number"; exit 2; }
}

# ------------------------------------------------------------------ unit and journal
journal_json() { journalctl --user -u "$UNIT" --since "@$SINCE" --until "@$UNTIL" -o json --no-pager 2>/dev/null || true; }

check_unit() {
  local j start done_ok failed
  j="$(journal_json)"
  # systemd's own job messages carry JOB_TYPE; "Starting" has no JOB_RESULT, "Finished" has done.
  start="$(jq -rs '[.[] | select(.JOB_TYPE == "start" and (.JOB_RESULT // "") == "")][0].__REALTIME_TIMESTAMP // empty' <<<"$j")"
  done_ok="$(jq -rs '[.[] | select(.JOB_TYPE == "start" and .JOB_RESULT == "done")] | length' <<<"$j")"
  failed="$(jq -rs '[.[] | select(.JOB_TYPE == "start" and .JOB_RESULT != null and .JOB_RESULT != "done")] | length' <<<"$j")"
  if [[ -z "$start" ]]; then
    failc unit "no start of $UNIT in the journal between $(iso "$SINCE") and $(iso "$UNTIL")"
    return
  fi
  start=$((start / 1000000))
  if ((start > SINCE + UNIT_START_MAX_S)); then
    failc unit "$UNIT started at $(iso "$start"), more than ${UNIT_START_MAX_S}s after SINCE"
  elif ((done_ok < 1 || failed > 0)); then
    failc unit "$UNIT started at $(iso "$start") but did not finish successfully (done=$done_ok failed=$failed)"
  else
    pass unit "$UNIT started at $(iso "$start") (SINCE + $((start - SINCE))s) and finished successfully"
  fi
}

check_journal() {
  local text
  text="$(journal_json | jq -r '.MESSAGE // empty | if type == "array" then implode else . end')"
  CAUSE="$(sed -n 's/.*cause: \([0-9a-f]\{40\}\).*/\1/p' <<<"$text" | head -n1)"
  BUMP="$(sed -n 's/.*bump: \([0-9a-f]\{40\}\).*/\1/p' <<<"$text" | head -n1)"
  if [[ -n "$CAUSE" && -n "$BUMP" ]]; then
    pass journal "the unit printed cause ${CAUSE:0:7} and bump ${BUMP:0:7}"
  else
    failc journal "no cause:/bump: SHA in the unit's journal in the window"
  fi
}

# ------------------------------------------------------------------ commits on the tracked branch
check_commits() {
  local list ops want msg
  list="$(gh api --paginate "repos/$REPO_SLUG/commits?sha=$TRACKED_BRANCH&since=$(iso "$SINCE")&until=$(iso "$UNTIL")&per_page=100" \
    --jq '.[] | {sha, login: (.author.login // ""), date: .commit.committer.date, parents: (.parents | length)}' 2>/dev/null)" || {
    failc commits "could not list commits on $TRACKED_BRANCH"; return; }
  # Operator commits: anything not authored by the bot (the bot's PR commits and its merge commit are
  # the agent's). Kept by committer date inside the window, oldest first.
  ops="$(jq -sr --arg bot "$BOT_LOGIN" --argjson s "$SINCE" --argjson u "$UNTIL" '
      [.[] | select(.login != $bot) | . + {t: (.date | fromdateiso8601)} | select(.t >= $s and .t <= $u)]
      | sort_by(.t) | .[].sha' <<<"$list")"
  want="$(printf '%s\n%s' "$CAUSE" "$BUMP")"
  if [[ -z "$CAUSE" || -z "$BUMP" ]]; then
    failc commits "no cause/bump from the journal to compare with: operator commits in the window: $(tr '\n' ' ' <<<"$ops")"
    return
  fi
  if [[ "$ops" != "$want" ]]; then
    failc commits "operator commits in the window are [$(tr '\n' ' ' <<<"$ops" | sed 's/ $//')], expected exactly the rearm pair [${CAUSE:0:7} ${BUMP:0:7}]"
    return
  fi
  msg="$(gh api "repos/$REPO_SLUG/commits/$CAUSE" --jq .commit.message)"
  if grep -qE '^Demo-Rearm: [0-9]+$' <<<"$msg"; then
    pass commits "the only operator commits in the window are the rearm pair; ${CAUSE:0:7} carries Demo-Rearm:"
  else
    failc commits "cause ${CAUSE:0:7} has no Demo-Rearm: trailer"
  fi
}

# ------------------------------------------------------------------ the PR
check_pr() {
  local prs n
  if [[ -n "$PR" ]]; then
    local login ref
    login="$(gh api "repos/$REPO_SLUG/pulls/$PR" --jq .user.login)"
    ref="$(gh api "repos/$REPO_SLUG/pulls/$PR" --jq .head.ref)"
    if [[ "$login" == "$BOT_LOGIN" && "$ref" == agent/checkout-* ]]; then
      pass pr "PR $PR (given) is from $BOT_LOGIN on $ref"
    else
      failc pr "PR $PR is from $login on $ref, not $BOT_LOGIN on agent/checkout-*"
    fi
    return
  fi
  prs="$(gh api --paginate "repos/$REPO_SLUG/pulls?state=all&sort=created&direction=desc&per_page=100" --jq '.[]' \
    | jq -sc --arg bot "$BOT_LOGIN" --argjson s "$SINCE" --argjson u "$UNTIL" '
        [.[] | select(.user.login == $bot and (.head.ref | startswith("agent/checkout-")))
             | (.created_at | fromdateiso8601) as $c | select($c >= $s and $c <= $u) | .number]')"
  n="$(jq length <<<"$prs")"
  if ((n == 1)); then
    PR="$(jq -r '.[0]' <<<"$prs")"
    pass pr "exactly one PR from $BOT_LOGIN opened in the window: $PR"
  else
    failc pr "$n PRs from $BOT_LOGIN on agent/checkout-* opened in the window ($(jq -r 'join(" ")' <<<"$prs")), expected exactly one"
  fi
}

check_merge() {
  local v merged_by auto merged_at t reviews
  if [[ -z "$PR" ]]; then
    failc merger "no PR to check"; failc merged "no PR to check"; failc reviews "no PR to check"; return
  fi
  v="$(gh pr view "$PR" --repo "$REPO_SLUG" --json mergedBy,autoMergeRequest,mergedAt,mergeCommit,headRefOid,reviews)"
  merged_by="$(jq -r '.mergedBy.login // ""' <<<"$v")"
  auto="$(jq -r 'if .autoMergeRequest then "yes" else "no" end' <<<"$v")"
  merged_at="$(jq -r '.mergedAt // ""' <<<"$v")"
  MERGE_SHA="$(jq -r '.mergeCommit.oid // ""' <<<"$v")"
  HEAD_SHA="$(jq -r '.headRefOid' <<<"$v")"
  # gh shows the App as "app/<slug>" or "<slug>"; BOT_LOGIN is "<slug>[bot]".
  local slug="${BOT_LOGIN%\[bot\]}"
  if [[ "$merged_by" == "$BOT_LOGIN" || "$merged_by" == "$slug" || "$merged_by" == "app/$slug" || "$auto" == yes ]]; then
    pass merger "merged by ${merged_by:-?} (autoMergeRequest: $auto)"
  else
    failc merger "merged by '${merged_by:-nobody}', not the bot, and no autoMergeRequest"
  fi
  if [[ -n "$merged_at" ]] && t="$(epoch_of "$merged_at")" && in_window "$t"; then
    pass merged "merged at $merged_at, inside the window"
  else
    failc merged "mergedAt '${merged_at:-none}' is not inside the window"
  fi
  reviews="$(jq '.reviews | length' <<<"$v")"
  if ((reviews == 0)); then
    pass reviews "no reviews"
  else
    failc reviews "$reviews review(s) on PR $PR: a human acted"
  fi
}

check_policy() {
  local run id concl log
  if [[ -z "${HEAD_SHA:-}" ]]; then failc check "no head SHA"; return; fi
  run="$(gh api "repos/$REPO_SLUG/commits/$HEAD_SHA/check-runs?check_name=$POLICY_CHECK_CONTEXT&per_page=100" \
    --jq "[.check_runs[] | select(.app.id == $POLICY_CHECK_INTEGRATION_ID)] | sort_by(.completed_at) | last // empty")"
  if [[ -z "$run" ]]; then failc check "no $POLICY_CHECK_CONTEXT check run on ${HEAD_SHA:0:7}"; return; fi
  id="$(jq -r .id <<<"$run")"
  concl="$(jq -r '.conclusion // "pending"' <<<"$run")"
  if [[ "$concl" != success ]]; then
    failc check "$POLICY_CHECK_CONTEXT concluded '$concl' on ${HEAD_SHA:0:7}"; return
  fi
  log="$(gh api "repos/$REPO_SLUG/actions/jobs/$id/logs" 2>/dev/null || true)"
  if [[ -z "$log" ]]; then
    failc check "$POLICY_CHECK_CONTEXT succeeded but its log (job $id) could not be read"
  # The log also echoes the step's script, so match conftest's own output, not the source text.
  elif grep -qE '^[^ ]+ PR author is not [^$]*: auto-fix rules skipped' <<<"$log" \
       || ! grep -qE 'Testing ".*facts\.json" against [0-9]+ policies in namespace "autofix"' <<<"$log"; then
    failc check "$POLICY_CHECK_CONTEXT succeeded but the auto-fix step did not run (job $id)"
  else
    pass check "$POLICY_CHECK_CONTEXT success on ${HEAD_SHA:0:7}, auto-fix conftest step ran (job $id)"
  fi
}

prom_at() { # EXPR EPOCH -> value (0 when empty)
  curl -sf --max-time 10 --get --data-urlencode "query=$1" --data-urlencode "time=$2" "${PROM_HOST_URL}/api/v1/query" \
    | jq -r '.data.result[0].value[1] // "0"'
}

check_metric() {
  local q='sum(aiops_policy_checks_total{result="pass"}) or vector(0)' a b
  a="$(prom_at "$q" "$SINCE")" || { failc metric "Prometheus query at SINCE failed"; return; }
  b="$(prom_at "$q" "$UNTIL")" || { failc metric "Prometheus query at UNTIL failed"; return; }
  if awk -v a="$a" -v b="$b" 'BEGIN {exit !(b + 0 >= a + 1)}'; then
    pass metric "aiops_policy_checks_total{result=\"pass\"} $a at SINCE, $b at UNTIL"
  else
    failc metric "aiops_policy_checks_total{result=\"pass\"} $a at SINCE, $b at UNTIL (expected at least +1)"
  fi
}

check_deployed() {
  local at t
  if [[ -z "$MERGE_SHA" ]]; then failc deployed "no merge SHA"; return; fi
  at="$(k get application checkout -n "$NS_ARGOCD" -o json \
    | jq -r --arg s "$MERGE_SHA" '[.status.history[]? | select(.revision == $s)] | first | .deployedAt // empty')"
  if [[ -n "$at" ]] && t="$(epoch_of "$at")" && in_window "$t"; then
    pass deployed "merge ${MERGE_SHA:0:7} deployed at $at (Application history)"
  else
    failc deployed "merge ${MERGE_SHA:0:7} not in the Application's history with deployedAt in the window (${at:-absent})"
  fi
}

check_incident() {
  local at t
  if [[ -z "$BUMP" ]]; then failc incident "no bump SHA from the journal"; return; fi
  at="$(curl -sf --max-time 5 "$(_sim_url)/incidents?app=checkout" \
    | jq -r --arg r "$BUMP" '[.[] | select(.revision == $r)] | max_by(.detected_at) | .resolved_at // empty')"
  if [[ -n "$at" ]] && t="$(epoch_of "$at")" && in_window "$t"; then
    pass incident "the incident for ${BUMP:0:7} resolved at $at"
  else
    failc incident "no incident for ${BUMP:0:7} resolved inside the window (${at:-none})"
  fi
}

main() {
  parse_args "$@"
  load_env
  require_context
  local root evdir
  root="$(main_root)"
  evdir="$(evidence_dir)/slice-5"
  mkdir -p "$evdir" "$root/.operator"
  OUT="$evdir/overnight-verify-$SINCE-$(date -u +%Y%m%dT%H%M%SZ).txt"
  : >"$OUT"
  say "overnight-verify: window $(iso "$SINCE") .. $(iso "$UNTIL")${PR:+ PR=$PR}"
  check_unit
  check_journal
  check_commits
  check_pr
  check_merge
  check_policy
  check_metric
  check_deployed
  check_incident
  if ((FAILS == 0)); then
    printf 'SINCE=%s\nUNTIL=%s\nPR=%s\nMERGE_SHA=%s\n' "$SINCE" "$UNTIL" "$PR" "$MERGE_SHA" >"$root/.operator/run-$SINCE"
    say "overnight-verify: PASS (window file .operator/run-$SINCE; output $OUT)"
  else
    say "overnight-verify: FAIL ($FAILS check(s); output $OUT)"
    exit 1
  fi
}

main "$@"
