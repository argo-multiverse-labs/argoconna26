#!/usr/bin/env bash
# Shared checks for the e2e scripts (tests/e2e/*.sh) and the demo-rung scripts' NO_WAIT checks.
#
# Source it after scripts/git-ops.sh and load_env. Every function is a predicate (exit 0 or 1,
# nothing on stdout unless it says so), so it works with wait_for and with `||`.
# GitHub reads use the caller's gh login (or GH_TOKEN); nothing here writes anywhere.
# shellcheck shell=bash

# ------------------------------------------------------------------ Argo CD
app_health_is() { # APP STATE
  [[ "$(k get application "$1" -n "$NS_ARGOCD" -o jsonpath='{.status.health.status}')" == "$2" ]]
}

app_sync_revision() { # APP -> the revision Argo last synced
  k get application "$1" -n "$NS_ARGOCD" -o jsonpath='{.status.sync.revision}'
}

app_synced_at() { # APP SHA : synced to SHA and the last operation succeeded
  local got
  got="$(k get application "$1" -n "$NS_ARGOCD" \
    -o jsonpath='{.status.sync.revision} {.status.sync.status} {.status.operationState.phase}')"
  [[ "$got" == "$2 Synced Succeeded" ]]
}

all_apps_synced_healthy() {
  k get applications -n "$NS_ARGOCD" -o json \
    | jq -e '[.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")] | length == 0' \
      >/dev/null
}

rollout_pod_hash() { # -> the checkout Rollout's current pod-template hash
  k get rollout checkout -n "$NS_DEMO" -o jsonpath='{.status.currentPodHash}'
}

# ------------------------------------------------------------------ GitHub
# tracked_file PATH : the file's content on the tracked branch, read through the API (not a clone).
tracked_file() {
  gh api -H 'Accept: application/vnd.github.raw' "repos/$REPO_SLUG/contents/$1?ref=$TRACKED_BRANCH"
}

tracked_level_is() { # LEVEL
  [[ "$(tracked_file "$AUTONOMY_FILE" | yq -r .level)" == "$1" ]]
}

# agent_prs_since T0 [APP] : PRs from BOT_LOGIN on agent/<app>-* branches created at or after
# T0 (epoch seconds), newest first, as JSON lines {number, url, state, created, branch}.
agent_prs_since() {
  local t0="$1" app="${2:-checkout}"
  gh api "repos/$REPO_SLUG/pulls?state=all&sort=created&direction=desc&per_page=30" \
    | jq -c --arg bot "$BOT_LOGIN" --arg pre "agent/$app-" --argjson t0 "$t0" '
        .[] | select(.user.login == $bot and (.head.ref | startswith($pre)))
        | (.created_at | fromdateiso8601) as $c | select($c >= $t0)
        | {number, url: .html_url, state, created: $c, branch: .head.ref}'
}

have_agent_pr_since() { [[ -n "$(agent_prs_since "$@")" ]]; } # T0 [APP]

open_agent_prs() { # [APP] -> numbers of open PRs from BOT_LOGIN on agent/<app>-*
  local app="${1:-checkout}"
  gh api "repos/$REPO_SLUG/pulls?state=open&per_page=100" \
    | jq -r --arg bot "$BOT_LOGIN" --arg pre "agent/$app-" \
        '.[] | select(.user.login == $bot and (.head.ref | startswith($pre))) | .number'
}

# fix_prs_on_github OUTCOME [APP] : how many PRs from BOT_LOGIN on agent/<app>-* are merged
# (OUTCOME merged) or closed unmerged (rejected), leaving out those labelled demo-reset or
# policy-negative-test. That is what the reconciler counts (Task 4.3a).
fix_prs_on_github() {
  local app="${2:-checkout}"
  gh api --paginate "repos/$REPO_SLUG/pulls?state=closed&per_page=100" --jq '.[]' \
    | jq -s --arg bot "$BOT_LOGIN" --arg pre "agent/$app-" --arg outcome "$1" '
        [.[] | select(.user.login == $bot and (.head.ref | startswith($pre)))
             | select((.merged_at != null) == ($outcome == "merged"))
             | select([.labels[].name] | index("demo-reset") or index("policy-negative-test") | not)]
        | length'
}

merged_fix_prs_on_github() { fix_prs_on_github merged "$@"; }   # [APP]
rejected_fix_prs_on_github() { fix_prs_on_github rejected "$@"; } # [APP]

pr_state_is() { # PR STATE (OPEN, CLOSED, MERGED)
  [[ "$(gh pr view "$1" --repo "$REPO_SLUG" --json state --jq .state)" == "$2" ]]
}

# assert_fix_pr_diff PR : exactly CONFIG_FILE and ROLLOUT_FILE, one changed line in each
# (one addition and one deletion), so two changed lines in total. Prints why on failure.
assert_fix_pr_diff() {
  local files want
  files="$(gh api "repos/$REPO_SLUG/pulls/$1/files" \
    --jq '[.[] | {filename, additions, deletions}] | sort_by(.filename)')" || return 1
  want="$(jq -nSc --arg a "$CONFIG_FILE" --arg b "$ROLLOUT_FILE" \
    '[{filename: $a, additions: 1, deletions: 1}, {filename: $b, additions: 1, deletions: 1}] | sort_by(.filename)')"
  files="$(jq -Sc . <<<"$files")" # sorted keys: GitHub's key order is not ours
  if [[ "$files" != "$want" ]]; then
    printf 'PR %s files: %s\nexpected: %s\n' "$1" "$files" "$want" >&2
    return 1
  fi
}

# fix_pr_footer LEVEL : the footer the bridge renders, read from the bridge's own section list.
fix_pr_footer() {
  yq -r ".footer.$1" "$(main_root)/bridge/src/bridge/templates/pr_sections.yaml"
}

# assert_fix_pr_body BODY CAUSE LEVEL : the policy-parsed Cause line and the level's footer.
assert_fix_pr_body() {
  local body="$1" cause="$2" footer
  footer="$(fix_pr_footer "$3")"
  grep -qE "^Cause: $cause( |\$)" <<<"$body" || { printf 'no "Cause: %s" line\n' "$cause" >&2; return 1; }
  grep -qF "$footer" <<<"$body" || { printf 'no %s footer: %s\n' "$3" "$footer" >&2; return 1; }
}

# bot_commit_comments SHA T0 : comments from BOT_LOGIN on commit SHA created at or after T0,
# as JSON lines {created, url, body}.
bot_commit_comments() {
  gh api "repos/$REPO_SLUG/commits/$1/comments" --paginate --jq '.[]' \
    | jq -c --arg bot "$BOT_LOGIN" --argjson t0 "$2" '
        select(.user.login == $bot) | (.created_at | fromdateiso8601) as $c | select($c >= $t0)
        | {created: $c, url: .html_url, body}'
}

have_bot_commit_comment() { [[ -n "$(bot_commit_comments "$1" "$2")" ]]; } # SHA T0

# ------------------------------------------------------------------ bridge
bridge_metric() { # SERIES -> its value, or 0 when absent. SERIES is name{labels} as /metrics prints it.
  local v
  v="$(curl -sf --max-time 5 "127.0.0.1:${PORT_BRIDGE}/metrics" | awk -v s="$1" '$1 == s {print $2}' | tail -n1)"
  printf '%s' "${v:-0}"
}

bridge_metric_is() { # SERIES N
  awk -v a="$(bridge_metric "$1")" -v b="$2" 'BEGIN {exit !(a + 0 == b + 0)}'
}

bridge_metric_at_least() { # SERIES N
  awk -v a="$(bridge_metric "$1")" -v b="$2" 'BEGIN {exit !(a + 0 >= b + 0)}'
}

bridge_status() { curl -sf --max-time 5 "127.0.0.1:${PORT_BRIDGE}/status"; }

# bridge_stage_lines SINCE_EPOCH : the bridge's stage lines (the "▸" ones) since then.
bridge_stage_lines() {
  k logs -n "$NS_AIOPS" deploy/bridge --since-time="$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ)" | grep '▸' || true
}

bridge_has_stage_line() { bridge_stage_lines "$1" | grep -qxF "$2"; } # SINCE LINE

# ------------------------------------------------------------------ timeline (cdevents-sim)
# sim_events_since APP TYPE T0 : events of TYPE for APP at or after T0, as JSON lines.
sim_events_since() {
  curl -sf --max-time 5 --get --data-urlencode "app=$1" --data-urlencode "type=$2" "$(_sim_url)/events" \
    | jq -c --argjson t0 "$3" '.[] | select((.timestamp | fromdateiso8601) >= $t0)'
}

have_sim_event_since() { [[ -n "$(sim_events_since "$@")" ]]; } # APP TYPE T0

incident_resolved_for() { # REVISION : the latest incident for it on /incidents is resolved
  curl -sf --max-time 5 "$(_sim_url)/incidents?app=checkout" \
    | jq -e --arg rev "$1" '[.[] | select(.revision == $rev)] | max_by(.detected_at) | .resolved_at != null' >/dev/null
}

# ------------------------------------------------------------------ Grafana
grafana_value_is() { # EXPR N : the expression evaluates to N through Grafana
  local v
  v="$(grafana_prom_value "$1")" || return 1
  [[ -n "$v" ]] && awk -v a="$v" -v b="$2" 'BEGIN {exit !(a + 0 == b + 0)}'
}

# grafana_prom_value EXPR : evaluate EXPR now through Grafana's query API (the panel's own
# datasource), print the first value. Admin credentials from .env, never on the command line.
grafana_prom_value() {
  local body
  body="$(jq -nc --arg e "$1" '{from: "now-5m", to: "now",
    queries: [{refId: "A", datasource: {type: "prometheus", uid: "prometheus"}, expr: $e,
               instant: true, range: false}]}')"
  curl -sf --max-time 10 -K <(printf 'user = "admin:%s"\n' "${GRAFANA_ADMIN_PASSWORD:?}") \
    -H 'Content-Type: application/json' -d "$body" "${GRAFANA_HOST_URL}/api/ds/query" \
    | jq -r '.results.A.frames[0].data.values[1][0] // empty'
}
