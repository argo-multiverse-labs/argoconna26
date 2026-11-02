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
#   DEMO_PACE    talk (default) or auto. Used by the scene scripts (demo-scene-N, demo-full):
#                talk stops for Enter only at scene_break, fourth_wall and speaker_beat, so the
#                speakers talk while the script waits on a condition. auto sets NO_WAIT=true:
#                nothing reads stdin and the e2e assertions run. The demo-rung-N scripts keep
#                their own pauses (every demo-magic wait) unless a scene script runs them.
#   NARRATION_DIR  where narrate looks (default <main checkout>/narration)
#   DEMO_OPEN   command that opens a URL in the browser (default xdg-open)
#   READY_TIMEOUT_S, READY_NOTE   per call of until_ready (see there)
#   DEMO_AUTOMERGE_FOR_TEST=1, DEMO_REJECT_FOR_TEST=1   honoured only with NO_WAIT=true, and
#                only by demo-rung-2.sh. Rung 3 never starts the helper: at act the merge must
#                be GitHub's auto-merge (or the bridge's catch-up), never a person.
#
# Scenes (O31). A scene script calls `scene_init NAME`, then scene_break, scene_say, fourth_wall
# and speaker_beat around the body of the matching rung script (those bodies are functions, so
# the failure branches are the rungs' own). Inside a scene, a failure branch that leaves the
# platform unfinished (handoff, no fix PR, policy left for review) exits 10, which demo-full
# treats as "stop here"; a refusal or a PII block ends after the human fix, exit 0.
#
#   scene_break TITLE        blank line, the title as one line, then Enter (talk pace)
#   fourth_wall TITLE        "-- TITLE --" (stepping out of the story), then Enter
#   speaker_beat WHO TOPIC   hand over to a character (the talk draft's cast): pe, the Platform
#                            Engineer; sre, the On-call SRE; or both. Prints "> Platform Engineer"
#                            or "> On-call SRE" or "> Both", keeps TOPIC
#                            in .operator/stage.log, then Enter. Outside a scene it is only the
#                            Enter. (The plan calls this `beat WHO TOPIC`; `beat TEXT` is already
#                            the one-line printer in common.sh, so this one has another name.)
#   scene_say KEY            narrate "$SCENE" KEY; nothing outside a scene
#   narrate SCENE KEY        print one section of narration/SCENE.txt
#
# Narration interface. narration/ is local only (excluded through .git/info/exclude; never in
# .gitignore, never committed). narration/<SCENE>.txt is split in sections: a section starts
# with a line `[KEY]`, and the non-blank lines after it, up to the next `[...]` line, belong to
# KEY. narrate prints those lines with demo-magic's `p` (the prompt, then the comment). A line
# starts with `# `; one that does not gets it. A line too long for the stage is folded at spaces
# to fit STAGE_COLS. A missing file or a missing KEY prints nothing and returns 0.
#
#   [push]
#   # An innocent release goes out.
#   [wait-teach]
#   # [SRE: read-only by default; dry runs]
#
# The On-call SRE's lines are placeholders only, in exactly this form, until that speaker writes
# them (tests/bats/demo_scenes.bats checks every line that opens a bracket): `# [SRE: <beat topic>]`.
# No speaker's real name appears in the scripts or the narration: the cues use the characters.
# The keys each scene uses: grep -ho 'scene_say [a-z0-9-]*' scripts/demo-*.sh
#
# Exit codes: 1 a failed assertion or an unexpected outcome, 3 wrong context, 4 a wait timed
# out, 5 cluster lock held, 6 autonomy not act (rung 3) or below propose (scene 3), 10 a scene
# ended early on a failure branch, plus those of the commands it runs.

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
DEMO_PACE="${DEMO_PACE:-talk}"
case "$DEMO_PACE" in
  talk) ;;
  auto) _want_no_wait=true ;;
  *) die "DEMO_PACE must be talk or auto" ;;
esac
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
# Scene scripts gate it: a wait reads a key only while a scene pause (_pause) has it open, so the
# typed commands and the narration lines of a scene never stop on their own.
SCENE="" _PACE_GATED=0 _PAUSE_OPEN=0
wait() {
  [[ "$NO_WAIT" == true ]] && return 0
  if [[ "$_PACE_GATED" == 1 && "$_PAUSE_OPEN" != 1 ]]; then return 0; fi
  _dm_wait
}
# Inside these scripts `wait` is the pause; a background job would be awaited with `builtin wait`.

# ---------------------------------------------------------------- prompts
DEMO_PROMPT_PLAIN='$ '
# shellcheck disable=SC2034 # DEMO_PROMPT is read by demo-magic
as_platform_engineer() { DEMO_PROMPT="\033[0;34mpe\\$ \033[0m"; DEMO_PROMPT_PLAIN='pe$ '; }
# shellcheck disable=SC2034 # DEMO_PROMPT is read by demo-magic
as_oncall_sre() { DEMO_PROMPT="\033[0;35msre\\$ \033[0m"; DEMO_PROMPT_PLAIN='sre$ '; }
as_platform_engineer

# rung_break TITLE : one plain line that starts a rung.
rung_break() { [[ -n "$SCENE" ]] || beat "== $1 =="; }

# ---------------------------------------------------------------- scenes (O31)
OVERNIGHT_VERIFY="${OVERNIGHT_VERIFY:-$DEMO_DIR/../tests/e2e/overnight-verify.sh}"
PROMOTION_PR_SH="${PROMOTION_PR_SH:-$DEMO_DIR/promotion-pr.sh}"

# scene_init NAME : this script is the scene NAME; waits now stop only at the scene pauses.
scene_init() { SCENE="$1" _PACE_GATED=1; }

_pause() {
  _PAUSE_OPEN=1
  wait
  _PAUSE_OPEN=0
}

scene_break() { # TITLE
  printf '\n'
  beat "$1"
  _pause
}

fourth_wall() { # TITLE
  local framed="-- $1 --"
  ((${#framed} <= STAGE_COLS)) || framed="$1"
  beat "$framed"
  _pause
}

speaker_beat() { # WHO TOPIC : WHO is pe (the Platform Engineer), sre (the On-call SRE) or both
  local who="$1" topic="${2:-}" name
  case "$who" in
    pe) name="Platform Engineer" ;;
    sre) name="On-call SRE" ;;
    both) name="Both" ;;
    *) die "speaker_beat: WHO must be pe, sre or both, got '$who'" ;;
  esac
  if [[ -n "$SCENE" ]]; then
    _stage_keep "beat: $who: $topic"
    beat "> $name"
  fi
  _pause
}

# narrate SCENE KEY : see the header. Always returns 0.
narrate() {
  local scene="$1" key="$2" file line chunk width
  local -a lines=()
  file="${NARRATION_DIR:-$(main_root)/narration}/$scene.txt"
  [[ -r "$file" ]] || return 0
  mapfile -t lines < <(awk -v want="[$key]" '
    { h = $0; sub(/[[:space:]]+$/, "", h) }
    h ~ /^\[[^]]*\]$/ { on = (h == want); next }
    on && NF { print }' "$file")
  width=$((STAGE_COLS - ${#DEMO_PROMPT_PLAIN} - 2))
  ((width >= 8)) || width=8
  for line in "${lines[@]}"; do
    line="${line#"# "}"
    line="${line#"#"}"
    while IFS= read -r chunk; do
      chunk="${chunk%"${chunk##*[![:space:]]}"}"
      p "# $chunk"
    done < <(printf '%s\n' "$line" | fold -s -w "$width")
  done
  return 0
}

scene_say() { [[ -z "$SCENE" ]] || narrate "$SCENE" "$1"; } # KEY

# leave_early : a failure branch ends the rung here. On stage a rung script exits 0; inside a
# scene, 10 tells demo-full to stop.
leave_early() { if [[ -n "$SCENE" ]]; then exit 10; fi; exit 0; }

# show_verify RUN_TS : run the after-the-fact verifier, show one short PASS/FAIL line per check
# and keep them in .operator/last-verify for the epilogue. Returns 1 when the verifier fails.
show_verify() {
  local out rc=0 line
  out="$("$OVERNIGHT_VERIFY" "SINCE=$1" "UNTIL=$(date +%s)" 2>&1)" || rc=$?
  mkdir -p "$OPERATOR_STATE"
  : >"$OPERATOR_STATE/last-verify"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    beat "${line:0:STAGE_COLS}"
    printf '%s\n' "${line:0:STAGE_COLS}" >>"$OPERATOR_STATE/last-verify"
  done < <(sed -nE 's/^(PASS|FAIL) ([A-Za-z0-9_-]+).*/\1 \2/p' <<<"$out")
  if ((rc != 0)); then
    beat "verify: FAIL"
    return 1
  fi
}

# promote_to LEVEL PR : verified, merged by people, recorded (the On-call SRE approves as the board).
# With NO_WAIT=true and DEMO_AUTOMERGE_FOR_TEST=1 an open promotion PR is merged here with
# --admin (logged as admin-bypass), which stands in for the board in a run nobody watches.
act_with_approval() { tracked_level_is act && [[ -n "$(autonomy_approved_by)" ]]; }

promote_to() {
  local level="$1" pr="$2" state
  "$PROMOTION_PR_SH" verify "$pr" # one line (P23); exit 8 and a refusal line when the PR changed
  open_tab "$(gh pr view "$pr" --repo "$REPO_SLUG" --json url --jq .url)"
  speaker_beat sre "approves the promotion"
  scene_say board
  state="$(gh pr view "$pr" --repo "$REPO_SLUG" --json state --jq .state 2>/dev/null || true)"
  if [[ "$state" == OPEN ]] && automerge_for_test; then "$PROMOTION_PR_SH" merge "$pr" --admin >/dev/null; fi
  READY_TIMEOUT_S="${PROMO_WAIT_S:-1800}" until_ready "promotion merged" pr_not_open "$pr"
  [[ "$(gh pr view "$pr" --repo "$REPO_SLUG" --json state --jq .state)" == MERGED ]] \
    || refuse 1 "promotion PR closed" "promotion PR $pr was closed, not merged"
  beat "promotion merged"
  "$PROMOTION_PR_SH" record-approval "$pr" # one line: recorded: board approval | admin bypass
  if [[ "$level" == act ]]; then
    until_ready "act, approved" act_with_approval
  else
    until_ready "propose, approved" propose_with_approval
  fi
}

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

# human_fix : the On-call SRE's beat, then the human fix (make fix, one pushed: line) until Healthy.
human_fix() {
  speaker_beat sre "before the human fix"
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
  local early=0
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
      early=1
      ;;
    other)
      beat "unknown bot comment"
      open_tab "$OUT_URL"
      early=1
      ;;
    *) return 1 ;;
  esac
  if [[ "$NO_WAIT" == true ]]; then
    log_error "FAIL: agent $OUT_KIND, not a fix"
    exit 1
  fi
  if ((early)); then leave_early; fi
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
  ) >/dev/null 2>&1 {CLUSTER_LOCK_FD}>&- & # never inherits the cluster lock's fd
  HELPER_PID=$!
  trap stop_pr_helper EXIT
}

# Only the helper this script started.
stop_pr_helper() {
  if [[ -n "$HELPER_PID" ]]; then kill "$HELPER_PID" 2>/dev/null || true; fi
}
