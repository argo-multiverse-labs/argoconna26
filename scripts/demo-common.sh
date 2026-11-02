#!/usr/bin/env bash
# Shared by scripts/demo-rung-{1,2,3}.sh (Task 6.4). Source it; do not execute it.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/demo-common.sh"
#
# It loads the environment, refuses a foreign kube context, exports STAGE=1 (P19: the operator
# scripts then print one short line per beat) and sources the vendored demo-magic.
# Every line these scripts print, and every prompt plus typed command, fits STAGE_COLS.
# No raw SHA and no "cause:" line reaches the terminal; machine values are read from
# <main checkout>/.operator/ (written by the operator scripts under STAGE=1) or from the
# rung-3 unit's journal.
#
# Environment:
#   TYPE_SPEED   typing speed for demo-magic (default 40; an empty value types instantly)
#   NO_WAIT      true: no pauses, and the script runs its assertions at the end (default false)
#   DEMO_OPEN    command that opens a URL in the browser (default xdg-open)
#   READY_TIMEOUT_S, READY_NOTE   per call of until_ready (see there)
#   DEMO_AUTOMERGE_FOR_TEST=1, DEMO_REJECT_FOR_TEST=1   honoured only with NO_WAIT=true, and
#                only by demo-rung-2.sh. Rung 3 never starts the helper: at act the merge must
#                be GitHub's auto-merge (or the bridge's catch-up), never a person.
# Exit codes: 1 a failed assertion or an unexpected outcome, 3 wrong context, 4 a wait timed
# out, 5 cluster lock held, 6 autonomy not act (rung 3), plus those of the commands it runs.

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$DEMO_DIR/common.sh"
# shellcheck source=tests/e2e/assert.sh
. "$DEMO_DIR/../tests/e2e/assert.sh"

load_env
require_context
export STAGE=1
STAGE_COLS="${STAGE_COLS:-30}"
export STAGE_COLS
cd "$(main_root)"
OPERATOR_STATE="$(main_root)/.operator"

# ---------------------------------------------------------------- demo-magic
# demo-magic sets TYPE_SPEED and NO_WAIT itself, so read ours first and put them back after.
# An empty TYPE_SPEED is kept: it means instant typing, which the non-interactive checks use.
_want_type_speed="${TYPE_SPEED-40}"
_want_no_wait="${NO_WAIT:-false}"
[[ "$_want_no_wait" == true || "$_want_no_wait" == false ]] || die "NO_WAIT must be true or false"
TYPE_SPEED=
# shellcheck source=scripts/demo-magic.sh
. "$DEMO_DIR/demo-magic.sh"
TYPE_SPEED="$_want_type_speed"
NO_WAIT="$_want_no_wait"
if [[ -n "$TYPE_SPEED" ]]; then check_pv; fi

# demo-magic's run_cmd turns terminal echo off and on with stty, which prints an error when
# there is no terminal (the non-interactive checks). Quiet it.
stty() { command stty "$@" 2>/dev/null || true; }

# demo-magic's wait reads a key. With NO_WAIT=true there is nobody to press it.
eval "_dm_$(declare -f wait)"
wait() { [[ "$NO_WAIT" == true ]] || _dm_wait; }
# Inside these scripts `wait` is the pause; a background job would be awaited with `builtin wait`.

# ---------------------------------------------------------------- prompts
DEMO_PROMPT_PLAIN='$ '
# shellcheck disable=SC2034 # DEMO_PROMPT is read by demo-magic
as_platform_engineer() { DEMO_PROMPT="\033[0;34mpe\\$ \033[0m"; DEMO_PROMPT_PLAIN='pe$ '; }
# shellcheck disable=SC2034 # DEMO_PROMPT is read by demo-magic
as_oncall_sre() { DEMO_PROMPT="\033[0;35msre\\$ \033[0m"; DEMO_PROMPT_PLAIN='sre$ '; }
as_platform_engineer

# rung_break TITLE : one plain line that starts a rung.
rung_break() { beat "== $1 =="; }

# typed COMMAND : demo-magic's pe, after checking that prompt plus command fit the stage pane.
# The typed commands run through demo-magic's eval in this shell. Under `make demo-rung-N` a
# nested make would print "make[1]: Entering directory ..." lines, wider than STAGE_COLS.
make() { command make "$@" --no-print-directory; }

typed() {
  if ((${#DEMO_PROMPT_PLAIN} + ${#1} > STAGE_COLS)); then
    refuse 1 "typed line too long" "typed command is too long for the stage: $1"
  fi
  pe "$1"
}

# until_ready DESC CMD... : one line, then wait for CMD to succeed (a real condition, never a
# sleep). READY_TIMEOUT_S sets the limit (default 300); READY_NOTE replaces the "waiting:" line
# with a plain "# NOTE" for a long wait ("# canary, about 60s"). Exit 4 on a timeout.
until_ready() {
  local desc="$1"
  shift
  if [[ -n "${READY_NOTE:-}" ]]; then beat "# $READY_NOTE"; else beat "waiting: $desc"; fi
  stage_wait "$desc" "${READY_TIMEOUT_S:-300}" "$@"
}

# check NAME CMD... : an assertion (NO_WAIT runs). Prints PASS, or the reason and exit 1.
check() {
  local name="$1"
  shift
  if "$@"; then
    beat "PASS: $name"
  else
    log_error "FAIL: $name"
    exit 1
  fi
}

# ---------------------------------------------------------------- browser
# open_tab URL : hand the URL to the browser. Tabs open in call order.
open_tab() {
  local opener="${DEMO_OPEN:-xdg-open}"
  if ! command -v "$opener" >/dev/null 2>&1; then
    beat "no browser opener"
    return 0
  fi
  "$opener" "$1" >/dev/null 2>&1 || true
}

argo_app_url() { printf '%s/applications/%s/checkout' "$ARGOCD_HOST_URL" "$NS_ARGOCD"; }
# The History and rollback panel. The rollback query parameter is how the Argo CD UI deep-links
# it (to be confirmed in the C6 visual pass); ARGO_HISTORY_URL overrides it.
argo_history_url() { printf '%s' "${ARGO_HISTORY_URL:-$(argo_app_url)?view=tree&rollback=0}"; }
grafana_kiosk_url() { "$DEMO_DIR/grafana-run-url.sh" --kiosk; }

# ---------------------------------------------------------------- state files
# machine_value FILE KEY : a "KEY: value" line the operator scripts wrote under STAGE=1.
machine_value() { sed -n "s/^$2: //p" "$OPERATOR_STATE/$1" 2>/dev/null | tail -n1; }

sha_ok() { [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]]; }

# ---------------------------------------------------------------- Argo CD
degraded_at() { # BUMP : the Application is Degraded at the bump revision
  [[ "$(app_sync_revision checkout)" == "$1" ]] && app_health_is checkout Degraded
}

refresh_checkout() { # O13: a read-only annotation through kubectl; the bridge never writes to the cluster
  k annotate application checkout -n "$NS_ARGOCD" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
}

# ---------------------------------------------------------------- GitHub
pr_not_open() { [[ "$(gh pr view "$1" --repo "$REPO_SLUG" --json state --jq .state)" != OPEN ]]; }
pr_merged_sha() { gh pr view "$1" --repo "$REPO_SLUG" --json mergeCommit --jq .mergeCommit.oid; }
pr_merged_by() { gh pr view "$1" --repo "$REPO_SLUG" --json mergedBy --jq '.mergedBy.login // ""'; }
pr_body() { gh pr view "$1" --repo "$REPO_SLUG" --json body --jq .body; }

autonomy_approved_by() { tracked_file "$AUTONOMY_FILE" | yq -r '.promotion.approved_by // ""'; }

propose_with_approval() {
  tracked_level_is propose && [[ -n "$(autonomy_approved_by)" ]]
}

# approved_by is a role, never a login and never the team.
approved_by_is_role() {
  local v
  v="$(autonomy_approved_by)"
  [[ "$v" == admin-bypass || "$v" =~ ^promotion-board\ member\ \(review\ https://github\.com/[^[:space:]]+\)$ ]] || {
    echo "approved_by is '$v'" >&2
    return 1
  }
}

# ---------------------------------------------------------------- the agent's outcome
# After T0 the agent leaves one of: an RCA comment, a fix PR, a refusal comment, a PII-blocked
# comment, or the HolmesGPT handoff comment. OUT_KIND is rca, pr, refused, pii, handoff or other.
OUT_KIND="" OUT_URL="" OUT_BODY="" OUT_PR="" # read by the rung scripts

# bot_comments_on T0 SHA... : JSON lines {created, url, body} from BOT_LOGIN on the commits and
# on the PRs that carry them, created at or after T0.
bot_comments_on() {
  local t0="$1" sha prs pr
  shift
  for sha in "$@"; do
    bot_commit_comments "$sha" "$t0" || true
    prs="$(gh api "repos/$REPO_SLUG/commits/$sha/pulls" --jq '.[].number' 2>/dev/null || true)"
    for pr in $prs; do
      gh api "repos/$REPO_SLUG/issues/$pr/comments" --paginate --jq '.[]' 2>/dev/null \
        | jq -c --arg bot "$BOT_LOGIN" --argjson t0 "$t0" '
            select(.user.login == $bot) | (.created_at | fromdateiso8601) as $c | select($c >= $t0)
            | {created: $c, url: .html_url, body}' || true
    done
  done
}

# have_outcome T0 WITH_PR APP SHA... : true once any bot outcome exists. WITH_PR is 1 on rungs
# 2 and 3, where a fix PR counts too.
have_outcome() {
  local t0="$1" with_pr="$2" app="$3"
  shift 3
  [[ -n "$(bot_comments_on "$t0" "$@")" ]] && return 0
  [[ "$with_pr" == 1 ]] && have_agent_pr_since "$t0" "$app"
}

classify_body() {
  if grep -q '^## Root cause' <<<"$1"; then echo rca
  elif grep -q '^## Agent refused' <<<"$1"; then echo refused
  elif grep -q '^## Agent output blocked' <<<"$1"; then echo pii
  elif grep -q 'a human should take this one' <<<"$1"; then echo handoff
  else echo other; fi
}

# read_outcome T0 WITH_PR APP SHA... : fill OUT_KIND, OUT_URL, OUT_BODY and OUT_PR.
read_outcome() {
  local t0="$1" with_pr="$2" app="$3" prs first
  shift 3
  OUT_KIND="" OUT_URL="" OUT_BODY="" OUT_PR=""
  if [[ "$with_pr" == 1 ]]; then
    prs="$(agent_prs_since "$t0" "$app" | head -n1)"
    if [[ -n "$prs" ]]; then
      # shellcheck disable=SC2034 # read by the rung scripts
      OUT_KIND=pr OUT_PR="$(jq -r .number <<<"$prs")" OUT_URL="$(jq -r .url <<<"$prs")"
      return 0
    fi
  fi
  first="$(bot_comments_on "$t0" "$@" | jq -sc 'sort_by(.created) | first // empty')"
  [[ -n "$first" ]] || return 1
  OUT_URL="$(jq -r .url <<<"$first")" OUT_BODY="$(jq -r .body <<<"$first")"
  OUT_KIND="$(classify_body "$OUT_BODY")"
}

# await_outcome T0 WITH_PR APP SHA... : wait for the outcome, then read it.
await_outcome() {
  until_ready "agent outcome" have_outcome "$@"
  read_outcome "$@" || die "the agent's outcome vanished"
}

refusal_reason() { sed -n 's/^- \([a-z_]*\): .*/\1/p' <<<"$OUT_BODY" | head -n1; }

# human_fix : Hilliary's beat, then the human fix (make fix, one pushed: line) until Healthy.
human_fix() {
  wait # Hilliary's beat
  as_platform_engineer
  typed "make fix"
  until_ready "Healthy" app_health_is checkout Healthy
  beat "healthy"
}

# unhappy_outcome : if the outcome is a refusal, a PII block or a handoff, show it as a feature
# (a guardrail working), finish the rung the way the draft says and exit. On stage that is
# exit 0. Under NO_WAIT=true the run still fails: the assertions need the RCA or PR path.
# Returns 1 when the outcome is an RCA comment or a fix PR, for the caller to carry on.
unhappy_outcome() {
  case "$OUT_KIND" in
    refused)
      beat "refused: $(refusal_reason)"
      open_tab "$OUT_URL"
      human_fix
      ;;
    pii)
      beat "blocked: pii"
      open_tab "$OUT_URL"
      human_fix
      ;;
    handoff)
      beat "handoff: cut to clip"
      ;;
    other)
      beat "unknown bot comment"
      open_tab "$OUT_URL"
      ;;
    *) return 1 ;;
  esac
  if [[ "$NO_WAIT" == true ]]; then
    log_error "FAIL: agent $OUT_KIND, not a fix"
    exit 1
  fi
  exit 0
}

# ---------------------------------------------------------------- test hooks (NO_WAIT only)
HELPER_PID=""
automerge_for_test() { [[ "$NO_WAIT" == true && "${DEMO_AUTOMERGE_FOR_TEST:-0}" == 1 ]]; }
reject_for_test() { [[ "$NO_WAIT" == true && "${DEMO_REJECT_FOR_TEST:-0}" == 1 ]]; }

# start_pr_helper T0 : in the background, merge the bot's fix PR (after policy-check passes) as
# soon as it appears, or close it with DEMO_REJECT_FOR_TEST=1. Stands in for the human in
# non-interactive checks. Does nothing unless NO_WAIT=true and a hook variable is set.
start_pr_helper() {
  local t0="$1"
  if ! automerge_for_test && ! reject_for_test; then return 0; fi
  (
    local pr
    wait_for "the bot's fix PR" 600 have_agent_pr_since "$t0" checkout
    pr="$(agent_prs_since "$t0" checkout | head -n1 | jq -r .number)"
    if reject_for_test; then
      gh pr close "$pr" --repo "$REPO_SLUG" --comment "Rejected by the NO_WAIT test hook." >/dev/null
    else
      wait_for "policy-check on PR $pr" 600 pr_policy_check_done "$pr"
      [[ "$(policy_check_conclusion "$(gh pr view "$pr" --repo "$REPO_SLUG" --json headRefOid --jq .headRefOid)")" == success ]]
      gh pr merge "$pr" --repo "$REPO_SLUG" --merge >/dev/null
    fi
  ) >/dev/null 2>&1 &
  HELPER_PID=$!
  trap stop_pr_helper EXIT
}

# Only the helper this script started.
stop_pr_helper() {
  if [[ -n "$HELPER_PID" ]]; then kill "$HELPER_PID" 2>/dev/null || true; fi
}
