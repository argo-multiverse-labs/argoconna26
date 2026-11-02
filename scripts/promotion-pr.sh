#!/usr/bin/env bash
# Promotion PRs and demotion for the agent's autonomy level (aiops/autonomy.yaml).
#
#   scripts/promotion-pr.sh ensure LEVEL          close any open promotion PR, open a fresh one for LEVEL
#   scripts/promotion-pr.sh close-open            close any open promotion PR (reset-rung-1 and reset-demo)
#   scripts/promotion-pr.sh verify PR             head and diff are what ensure pushed (exit 8 if not)
#   scripts/promotion-pr.sh merge PR [--admin]    verify, then merge (--admin is logged as admin-bypass)
#   scripts/promotion-pr.sh record-approval PR    after the merge: write who approved, as a role plus a link
#   scripts/promotion-pr.sh demote                one level down, as a forward commit on the tracked branch
#
# The PR is opened with the operator's own gh login, so that person is the author and GitHub
# will not let them approve it: the other board member approves, or an admin merges with
# --admin (D5). Nothing here uses the GitHub App. The PR body comes only from
# scripts/templates/promotion-pr-body.md; no text can be passed in.
# Git work happens in the operator clone (scripts/git-ops.sh), under the cluster lock.
# `ensure` pushes only a promote/* branch; `record-approval` and `demote` push to the tracked
# branch (direct pushes by a repo admin; lowering trust is fail-safe, and the record changes no level).
#
# Test overrides: PROMOTION_STAMP (UTC yyyymmddHHMMSS, the branch name and today's date).
# Exit codes: 1 generic, 8 verify failed, plus those of common.sh.
set -euo pipefail
# shellcheck source=scripts/git-ops.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-ops.sh"

PROMOTION_BODY_TEMPLATE="$GIT_OPS_DIR/templates/promotion-pr-body.md"
LEVELS=(suggest propose act)
EXIT_VERIFY=8

# ---------------------------------------------------------------- levels
# level_index LEVEL : print 0..2, or return 1 for anything else.
level_index() {
  local i
  for i in "${!LEVELS[@]}"; do
    if [[ "${LEVELS[i]}" == "$1" ]]; then printf '%s' "$i"; return 0; fi
  done
  return 1
}

current_level() {
  local lvl
  lvl="$(yaml_get "$AUTONOMY_FILE" .level)"
  level_index "$lvl" >/dev/null || die "$AUTONOMY_FILE: level is '$lvl', expected one of ${LEVELS[*]}"
  printf '%s' "$lvl"
}

# ------------------------------------------------------------------ time
utc_stamp() { printf '%s' "${PROMOTION_STAMP:-$(date -u +%Y%m%d%H%M%S)}"; }

utc_today() { # yyyy-mm-dd, from the stamp
  local s
  s="$(utc_stamp)"
  printf '%s-%s-%s' "${s:0:4}" "${s:4:2}" "${s:6:2}"
}

random4() {
  local alphabet=abcdefghijklmnopqrstuvwxyz0123456789 out="" _
  for _ in 1 2 3 4; do out+="${alphabet:RANDOM%36:1}"; done
  printf '%s' "$out"
}

# time_at_level SINCE : "3 days (since 2026-11-02)"
time_at_level() {
  local since="$1" a b days
  a="$(date -u -d "$since" +%s 2>/dev/null)" || die "cannot read since: '$since'"
  b="$(date -u -d "$(utc_today)" +%s)"
  days=$(((b - a) / 86400))
  ((days >= 0)) || days=0
  if ((days == 1)); then printf '1 day (since %s)' "$since"; else printf '%s days (since %s)' "$days" "$since"; fi
}

# ----------------------------------------------------------------- score
# The dry-run result: "M/N" from .dryruns/summary.json, or "pending" before the harness has run.
dry_run_score() {
  local f out
  f="$(main_root)/.dryruns/summary.json"
  [[ -r "$f" ]] || { printf 'pending'; return 0; }
  out="$(jq -r 'select((.n | type) == "number" and .n > 0 and (.root_cause_matched | type) == "number")
                | "\(.root_cause_matched)/\(.n)"' "$f" 2>/dev/null || true)"
  printf '%s' "${out:-pending}"
}

# dry_run_detail : " Measured as M/N dry runs across I incidents (R runs each, temperature T, model `ID`)."
# from .dryruns/summary.json (Δ27, D17), or nothing when the summary lacks any of it. The model ID
# lands in a public PR body, so anything but a plain model name leaves the whole sentence out.
dry_run_detail() {
  local f
  f="$(main_root)/.dryruns/summary.json"
  [[ -r "$f" ]] || return 0
  jq -r 'def plural(n; w): "\(n) \(w)\(if n == 1 then "" else "s" end)";
    select((.n | type) == "number" and .n > 0 and (.root_cause_matched | type) == "number"
      and (.incidents | type) == "number" and .incidents > 0
      and (.runs_per_incident | type) == "number" and .runs_per_incident > 0
      and (.model_temperature | type) == "number"
      and (.model_id | type) == "string" and (.model_id | test("^[A-Za-z0-9._:/@-]{1,100}$")))
    | " Measured as \(.root_cause_matched)/\(.n) dry runs across \(plural(.incidents; "incident"))"
      + " (\(plural(.runs_per_incident; "run")) each, temperature \(.model_temperature), model `\(.model_id)`)."' \
    "$f" 2>/dev/null || true
}

# score_verdict SCORE : the plain sentence for the body; returns 1 when the score is below the bar.
score_verdict() {
  local score="$1" bar="$PROMOTION_SCORE_BAR" m n bm bn
  bm="${bar%/*}" bn="${bar#*/}"
  if [[ "$score" =~ ^([0-9]+)/([0-9]+)$ ]]; then
    m="${BASH_REMATCH[1]}" n="${BASH_REMATCH[2]}"
    if ((n >= bn && m * bn >= bm * n)); then
      printf 'Score %s meets our %s bar.' "$score" "$bar"
      return 0
    fi
    printf 'Score %s is below our %s bar.' "$score" "$bar"
    return 1
  fi
  printf 'No score yet, so we are below our %s bar.' "$bar"
  return 1
}

# ------------------------------------------------------------------ body
# render_body FROM TO SCORE SINCE OUTFILE : the template with its variables filled in, nothing else.
render_body() {
  local from="$1" to="$2" score="$3" since="$4" out="$5" weeks_var verdict
  weeks_var="PROMOTION_WEEKS_${from^^}"
  verdict="$(score_verdict "$score")" || log_warn "score $score is below the $PROMOTION_SCORE_BAR bar; the PR body says so"
  # shellcheck disable=SC2016 # envsubst variable names, not shell expansions
  FROM_LEVEL="$from" TO_LEVEL="$to" VERDICT="$verdict" DRY_RUN_DETAIL="$(dry_run_detail)" \
    TIME_AT_LEVEL="$(time_at_level "$since")" WEEKS="${!weeks_var:?$weeks_var is not set in demo.env}" \
    APPROVER="$PROMOTION_TEAM" \
    envsubst '${FROM_LEVEL} ${TO_LEVEL} ${VERDICT} ${DRY_RUN_DETAIL} ${TIME_AT_LEVEL} ${WEEKS} ${APPROVER}' \
    <"$PROMOTION_BODY_TEMPLATE" >"$out"
}

# ------------------------------------------------------------ gh helpers
# Everything runs as the operator's gh login (or GH_TOKEN, when set), never the App.
gh_open_promotion_prs() { # -> PR numbers, one per line
  gh pr list --repo "$REPO_SLUG" --state open --limit 100 --json number,headRefName \
    --jq '.[] | select(.headRefName | startswith("promote/")) | .number'
}

# approving_review_url PR HEAD : the URL of an approval that still stands on HEAD, or nothing.
# Per human reviewer, the latest review that decides (COMMENTED and PENDING don't withdraw an
# approval on GitHub, so they are dropped first) must be APPROVED and on HEAD (the head ensure
# pushed). Bots and BOT_LOGIN never count: an App approval is not a promotion-board review.
# The reviewer must be an active member of PROMOTION_TEAM (the repo is public, so anyone can
# leave an approving review). Only the URL leaves this function; logins are used for the checks
# and dropped.
approving_review_url() {
  local reviews candidates login url org="${PROMOTION_TEAM#@}" found=""
  local team="${org#*/}"
  org="${org%%/*}"
  reviews="$(gh api "repos/${REPO_SLUG}/pulls/$1/reviews?per_page=100")" || return 1
  candidates="$(jq -r --arg bot "${BOT_LOGIN:?}" --arg head "$2" '
    [.[] | select(.state != "COMMENTED" and .state != "PENDING")
         | select(.user.type != "Bot" and .user.login != $bot)]
    | [group_by(.user.login)[] | last | select(.state == "APPROVED" and .commit_id == $head)]
    | sort_by(.id) | .[] | "\(.user.login) \(.html_url)"' <<<"$reviews")" || return 1
  while read -r login url; do
    [[ -n "$login" ]] || continue
    if [[ "$(gh api "orgs/$org/teams/$team/memberships/$login" --jq .state 2>/dev/null)" == active ]]; then
      found="$url"
    fi
  done <<<"$candidates"
  [[ -z "$found" ]] || printf '%s\n' "$found"
}

# ------------------------------------------------------- recorded promotions
# $(main_root)/.operator/promotion-<level> holds pr=, head= and branch= of the PR ensure opened.
record_file() { printf '%s/.operator/promotion-%s' "$(main_root)" "$1"; }

# recorded_file_for PR : the record file that names PR, or nothing.
recorded_file_for() {
  local f
  for f in "$(main_root)"/.operator/promotion-*; do
    [[ -f "$f" ]] || continue
    if grep -qx "pr=$1" "$f"; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

record_value() { sed -n "s/^$2=//p" "$1" | head -n1; } # FILE KEY

require_pr_number() { [[ "${1:-}" =~ ^[0-9]+$ ]] || die "PR must be a number, got '${1:-}'"; }

# --------------------------------------------------------------- ensure
close_stale_promotion_prs() { # [COMMENT]
  local n stale comment="${1:-superseded by a fresh promotion PR}"
  stale="$(gh_open_promotion_prs)" || die "could not list open promotion PRs"
  while read -r n; do
    [[ -n "$n" ]] || continue
    gh pr close "$n" --repo "$REPO_SLUG" --comment "$comment" >/dev/null \
      || die "could not close the stale promotion PR $n"
    log_info "closed superseded promotion PR $n"
  done <<<"$stale"
}

# set_promotion TO FROM SCORE TODAY : level, since and the promotion record, in the operator clone.
set_promotion() {
  YQ_TO="$1" YQ_FROM="$2" YQ_SCORE="$3" YQ_TODAY="$4" YQ_TEAM="$PROMOTION_TEAM" \
    yq -i '.level = strenv(YQ_TO) | .since = strenv(YQ_TODAY)
      | .promotion = {"from_level": strenv(YQ_FROM), "dry_run_score": strenv(YQ_SCORE),
                      "approver_required": strenv(YQ_TEAM), "approved_by": null, "pr": null}' \
    "$(op_path "$AUTONOMY_FILE")"
}

cmd_ensure() {
  (($# == 1)) || die "usage: promotion-pr.sh ensure LEVEL   (no other arguments; the body comes from the template)"
  local to="$1" to_idx cur cur_idx score today branch body url pr head
  to_idx="$(level_index "$to")" || die "unknown level '$to' (expected propose or act)"
  ((to_idx >= 1)) || die "cannot promote to suggest; use: demote"
  cluster_lock
  machine_init last-promotion
  op_sync
  cur="$(current_level)"
  cur_idx="$(level_index "$cur")"
  if ((cur_idx + 1 != to_idx)); then
    refuse 1 "level is $cur" "ensure: level is $cur; a promotion to $to needs ${LEVELS[to_idx - 1]} first"
  fi
  close_stale_promotion_prs

  score="$(dry_run_score)"
  today="$(utc_today)"
  branch="promote/${to}-$(utc_stamp)-$(random4)"
  body="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$body'; _ensure_restore '$branch'" EXIT
  render_body "$cur" "$to" "$score" "$(yaml_get "$AUTONOMY_FILE" .since)" "$body"

  _ogq checkout --quiet -b "$branch"
  set_promotion "$to" "$cur" "$score" "$today"
  _ogq add -- "$AUTONOMY_FILE"
  _og diff --cached --quiet && die "ensure: the promotion changes nothing in $AUTONOMY_FILE"
  _ogq commit --quiet -m "chore(autonomy): promote $cur to $to" || die "commit was refused (pre-commit hook?)"
  head="$(_og rev-parse HEAD)"
  _ogq push --quiet origin "HEAD:refs/heads/$branch" || die "could not push $branch"

  url="$(gh pr create --repo "$REPO_SLUG" --base "$TRACKED_BRANCH" --head "$branch" \
    --title "Promote the agent from $cur to $to" --body-file "$body")" || die "could not open the promotion PR"
  pr="${url##*/}"
  require_pr_number "$pr"
  mkdir -p "$(dirname "$(record_file "$to")")"
  printf 'pr=%s\nhead=%s\nbranch=%s\n' "$pr" "$head" "$branch" >"$(record_file "$to")"

  beat "promotion PR open"
  machine_line pr "$pr"
  machine_line branch "$branch"
  machine_line head "$head"
}

# Back on the tracked branch with no leftovers, however ensure ended.
_ensure_restore() {
  _og reset --quiet --hard >/dev/null 2>&1 || true
  _og checkout --quiet "$TRACKED_BRANCH" >/dev/null 2>&1 || true
  _og branch --quiet -D "$1" >/dev/null 2>&1 || true
}

# --------------------------------------------------------- verify, merge
# verify_promotion PR : sets RECORDED_FILE and RECORDED_HEAD, or exits 8 naming what differs.
verify_promotion() {
  local pr="$1" head names problems=()
  require_pr_number "$pr"
  RECORDED_FILE="$(recorded_file_for "$pr" || true)"
  [[ -n "$RECORDED_FILE" ]] || refuse "$EXIT_VERIFY" "unknown promotion" "verify: no recorded promotion for PR $pr (ensure did not open it)"
  RECORDED_HEAD="$(record_value "$RECORDED_FILE" head)"
  head="$(gh pr view "$pr" --repo "$REPO_SLUG" --json headRefOid --jq .headRefOid)" || die "could not read PR $pr"
  names="$(gh pr diff "$pr" --repo "$REPO_SLUG" --name-only)" || die "could not read the diff of PR $pr"
  [[ "$head" == "$RECORDED_HEAD" ]] || problems+=("head moved: PR is at ${head:0:12}, ensure pushed ${RECORDED_HEAD:0:12}")
  [[ "$names" == "$AUTONOMY_FILE" ]] || problems+=("diff is not only $AUTONOMY_FILE: $(tr '\n' ' ' <<<"$names")")
  if ((${#problems[@]} > 0)); then
    refuse "$EXIT_VERIFY" "promotion PR changed" "verify: PR $pr: $(printf '%s; ' "${problems[@]}")"
  fi
}

cmd_verify() {
  (($# == 1)) || die "usage: promotion-pr.sh verify PR"
  verify_promotion "$1"
  if stage_on; then beat "promotion PR: clean"; else beat "promotion PR $1: clean"; fi
}

cmd_merge() {
  local pr="${1:-}" admin=0 args
  (($# >= 1 && $# <= 2)) || die "usage: promotion-pr.sh merge PR [--admin]"
  if (($# == 2)); then
    [[ "$2" == "--admin" ]] || die "usage: promotion-pr.sh merge PR [--admin]"
    admin=1
  fi
  verify_promotion "$pr"
  args=(pr merge "$pr" --repo "$REPO_SLUG" --merge --match-head-commit "$RECORDED_HEAD")
  if ((admin)); then
    args+=(--admin)
    log_info "admin-bypass: merging PR $pr without a review"
  elif [[ -z "$(approving_review_url "$pr" "$RECORDED_HEAD")" ]]; then
    refuse 1 "no approving review" "merge: PR $pr has no approving review; get one, or pass --admin (logged as admin-bypass)"
  fi
  gh "${args[@]}" >/dev/null || die "gh could not merge PR $pr"
  if ((admin)); then beat "merged: admin-bypass"; else beat "merged"; fi
}

# ------------------------------------------------------- record-approval
cmd_record_approval() {
  (($# == 1)) || die "usage: promotion-pr.sh record-approval PR"
  local pr="$1" file level state url value
  require_pr_number "$pr"
  file="$(recorded_file_for "$pr" || true)"
  [[ -n "$file" ]] || refuse 1 "unknown promotion" "record-approval: no recorded promotion for PR $pr"
  level="${file##*/promotion-}"
  state="$(gh pr view "$pr" --repo "$REPO_SLUG" --json state --jq .state)" || die "could not read PR $pr"
  [[ "$state" == MERGED ]] || refuse 1 "PR is $state" "record-approval: PR $pr is $state, not MERGED"

  url="$(approving_review_url "$pr" "$(record_value "$file" head)")" || die "could not read the reviews of PR $pr"
  if [[ -n "$url" ]]; then
    value="promotion-board member (review $url)"
  else
    value="admin-bypass"
  fi

  cluster_lock
  op_sync
  [[ "$(yaml_get "$AUTONOMY_FILE" .level)" == "$level" ]] \
    || refuse 1 "level is not $level" "record-approval: the tracked level is not $level; nothing to record"
  if [[ "$(yaml_get "$AUTONOMY_FILE" .promotion.approved_by)" != null ]]; then
    [[ "$(yaml_get "$AUTONOMY_FILE" .promotion.pr)" == "$pr" ]] \
      || refuse 1 "other approval on file" "record-approval: the tracked promotion record already belongs to another PR"
    beat "already recorded"
    return 0
  fi
  YQ_PR="$pr" yq -i '.promotion.pr = (strenv(YQ_PR) | tonumber)' "$(op_path "$AUTONOMY_FILE")"
  yaml_set "$AUTONOMY_FILE" .promotion.approved_by "$value"
  op_commit_push "chore(autonomy): record approval for promotion PR $pr" "$AUTONOMY_FILE" >/dev/null
  if [[ "$value" == admin-bypass ]]; then beat "recorded: admin bypass"; else beat "recorded: board approval"; fi
}

# ---------------------------------------------------------------- demote
cmd_demote() {
  (($# == 0)) || die "usage: promotion-pr.sh demote"
  local cur idx prev
  cluster_lock
  op_sync
  cur="$(current_level)"
  idx="$(level_index "$cur")"
  ((idx >= 1)) || refuse 1 "already suggest" "demote: the level is already suggest"
  prev="${LEVELS[idx - 1]}"
  YQ_PREV="$prev" YQ_TODAY="$(utc_today)" \
    yq -i '.level = strenv(YQ_PREV) | .since = strenv(YQ_TODAY) | .promotion = null' "$(op_path "$AUTONOMY_FILE")"
  op_commit_push "chore(autonomy): demote $cur to $prev" "$AUTONOMY_FILE" >/dev/null
  beat "demoted: $cur -> $prev"
}

# ------------------------------------------------------------ dispatcher
main() {
  local cmd="${1:-}"
  shift || true
  load_env
  : "${PROMOTION_SCORE_BAR:?PROMOTION_SCORE_BAR is not set in demo.env}"
  [[ "$PROMOTION_SCORE_BAR" =~ ^[0-9]+/[0-9]+$ ]] || die "PROMOTION_SCORE_BAR must look like 20/20"
  case "$cmd" in
    ensure) cmd_ensure "$@" ;;
    verify) cmd_verify "$@" ;;
    merge) cmd_merge "$@" ;;
    record-approval) cmd_record_approval "$@" ;;
    demote) cmd_demote "$@" ;;
    close-open) (($# == 0)) || die "usage: promotion-pr.sh close-open"; close_stale_promotion_prs "closed by a demo reset" ;;
    *) die "usage: promotion-pr.sh ensure LEVEL | verify PR | merge PR [--admin] | record-approval PR | demote | close-open" ;;
  esac
}

main "$@"
