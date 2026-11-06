#!/usr/bin/env bash
# Shared by scripts/demo-rung-{1,2,3}.sh (Task 6.4). Source it; do not execute it.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/demo-common.sh"
#
# It loads the environment, refuses a foreign kube context, exports STAGE=1 (P19: the operator
# scripts then print one short line per beat) and sources the vendored demo-magic.
# Text is never folded or cut to a width: a long line wraps where the terminal wraps it. Only the
# bars, title cards and the wait spinner use STAGE_COLS, which here is the width of the demo
# terminal (DEMO_COLS, below), not demo.env's 30.
# No raw SHA and no "cause:" line reaches the terminal; machine values are read from
# <main checkout>/.operator/ (written by the operator scripts under STAGE=1) or from the
# rung-3 unit's journal.
#
# Environment:
#   TYPE_SPEED   typing speed for demo-magic (default 40; an empty value types instantly)
#   NO_WAIT      true: no pauses, and the script runs its assertions at the end (default false)
#   DEMO_PACE    talk (default) or auto. Used by the scene scripts (demo-scene-N, demo-full):
#                talk stops for Enter at scene_break, fourth_wall and speaker_beat, and before
#                each line of narration (DEMO_STEP), never at a typed command or a wait, so the
#                speakers talk while the script waits on a condition. auto sets NO_WAIT=true:
#                nothing reads stdin and the e2e assertions run. The demo-rung-N scripts keep
#                their own pauses (every demo-magic wait) unless a scene script runs them.
#   DEMO_STEP    line (default): in talk pace, each narration line waits for Enter, so the
#                speaker says it as it appears. section: a narration section types out whole.
#   NARRATION_DIR  where narrate looks (default <main checkout>/narration)
#   DEMO_COLS   width the bars and title cards fill (text is not wrapped to it). Unset: the
#               terminal's own width; 78 when stdout is not a terminal. Set (.env or the
#               caller): used as is, at least 30.
#   DEMO_OPEN   command that opens a URL in the browser, split into words (default xdg-open, or
#               open on macOS). `google-chrome` opens a new tab in the Chrome that is already
#               running; `true` opens nothing. The tests point it at a logger.
#   The caller's DEMO_COLS, DEMO_OPEN and DEMO_STEP win over .env (a test's logger stays a logger).
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
#                            Engineer; sre, the On-call SRE; or both. Prints that character's bar
#                            ("━━ On-call SRE ━━━"), keeps TOPIC in .operator/stage.log, then
#                            Enter. Outside a scene there is no bar. (The plan calls this `beat
#                            WHO TOPIC`; `beat TEXT` is already the one-line printer in common.sh.)
#   cue WHO                  WHO takes the floor without a pause: the bar (in a scene, when the
#                            speaker changes) and WHO's prompt. The prompt always follows the last
#                            bar: speaker_beat and narrate go through cue, so a bar for the
#                            On-call SRE is followed by [SRE]$, never [PE]$.
#   scene_say KEY            narrate "$SCENE" KEY; nothing outside a scene
#   narrate SCENE KEY        print one section of narration/SCENE.txt
#   typed CMD                type CMD at the prompt and run it (demo-magic's pe)
#   shown DISPLAY CMD...     type DISPLAY at the prompt, then run CMD: for what a script does
#                            for the speakers (a push, a merge, a promotion), so the audience sees
#                            the real command. DISPLAY is that command as the audience reads it.
#   note TEXT                one plain line, "› TEXT", for plumbing with no command worth showing
#   look WHERE [URL]         where the audience should look now: "▶ WHERE", then opens URL (if
#                            given) in the browser. Every page a scene points at gets one.
#
# Narration interface. narration/ is local only (excluded through .git/info/exclude; never in
# .gitignore, never committed). narration/<SCENE>.txt is split in sections: a section starts
# with a line `[KEY]`, and the lines after it, up to the next `[...]` line, belong to KEY.
# narrate prints them with demo-magic's `p` (the prompt, then the comment). The leading `# ` of a
# line is dropped and the lines are joined: the file's line breaks do not matter. A blank line
# inside a section starts a new paragraph, and each paragraph prints as one line, never folded:
# the terminal wraps a long one at its own width. A missing file or a missing KEY prints nothing and
# returns 0.
#
#   [push]
#   # An innocent release goes out. Nothing in it
#   # looks wrong.
#   [wait-teach]
#   # [SRE: read-only by default; dry runs]
#
# The On-call SRE's lines are drafts for that speaker to rewrite in her own words. A line that
# opens a bracket is a placeholder, in exactly this form (tests/bats/demo_scenes.bats checks
# them): `# [SRE: <beat topic>]`.
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

_caller_demo_open="${DEMO_OPEN:-}" _caller_demo_cols="${DEMO_COLS:-}" _caller_demo_step="${DEMO_STEP:-}"
load_env
require_context
[[ -z "$_caller_demo_open" ]] || DEMO_OPEN="$_caller_demo_open"
[[ -z "$_caller_demo_cols" ]] || DEMO_COLS="$_caller_demo_cols"
[[ -z "$_caller_demo_step" ]] || DEMO_STEP="$_caller_demo_step"
export STAGE=1

# The bar width. demo.env's STAGE_COLS (30) is what every operator line and the bridge's stage
# log fit; the demo terminal is wider, and its bars fill it (see DEMO_COLS in the header).
DEMO_COLS_DEFAULT=78 DEMO_COLS_MIN=30
_set_stage_cols() {
  local n="${DEMO_COLS:-}" size
  if [[ -z "$n" ]]; then
    n="$DEMO_COLS_DEFAULT"
    if [[ -t 1 ]]; then
      size="$(command stty size </dev/tty 2>/dev/null || true)"
      size="${size##* }"
      if [[ "$size" =~ ^[0-9]+$ ]] && ((size > 0)); then n="$size"; fi
    fi
  fi
  [[ "$n" =~ ^[0-9]+$ ]] || die "DEMO_COLS must be a number of columns, got '$n'"
  ((n >= DEMO_COLS_MIN)) || n="$DEMO_COLS_MIN"
  STAGE_COLS="$n"
}
_set_stage_cols
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
DEMO_STEP="${DEMO_STEP:-line}"
[[ "$DEMO_STEP" == line || "$DEMO_STEP" == section ]] || die "DEMO_STEP must be line or section"
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

# ---------------------------------------------------------------- theme and prompts
# Like argoconeu26: each character has a bold, colour-coded prompt, a speaker change is a bar in
# that character's colour, and a scene starts between two bars. DEMO_THEME matches the stage
# terminal: light (default, the 11-09 setup) or dark.
DEMO_THEME="${DEMO_THEME:-light}"
case "$DEMO_THEME" in
  light) C_PE='1;34' C_SRE='1;35' C_BOTH='1;32' C_SCENE='1;30' C_WALL='3;90' C_LOOK='1;36' ;;
  dark) C_PE='1;94' C_SRE='1;95' C_BOTH='1;92' C_SCENE='1;33' C_WALL='3;37' C_LOOK='1;96' ;;
  *) die "DEMO_THEME must be light or dark, got '$DEMO_THEME'" ;;
esac
DEMO_PROMPT_PLAIN='$ '
_as() { # COLOUR LABEL
  # shellcheck disable=SC2034 # DEMO_PROMPT is read by demo-magic
  DEMO_PROMPT="\033[${1}m[$2]\033[0m\\$ "
  DEMO_PROMPT_PLAIN="[$2]\$ "
}
as_platform_engineer() { _as "$C_PE" PE; }
as_oncall_sre() { _as "$C_SRE" SRE; }
as_both() { _as "$C_BOTH" ALL; }
as_platform_engineer
_role_prompt() { # WHO : pe, sre or both
  case "$1" in
    pe) as_platform_engineer ;;
    sre) as_oncall_sre ;;
    both) as_both ;;
    *) die "WHO must be pe, sre or both, got '$1'" ;;
  esac
}

# _bar CHAR COLOUR [TITLE] : a STAGE_COLS-wide line of CHAR in COLOUR, with TITLE set in after two
_bar() {
  local ch="$1" colour="$2" title="${3:-}" line fill
  line="${title:+$ch$ch $title }"
  ((${#line} <= STAGE_COLS)) || line="${line:0:STAGE_COLS}"
  fill=$((STAGE_COLS - ${#line}))
  ((fill > 0)) && line+="$(printf "$ch%.0s" $(seq "$fill"))"
  printf '\033[%sm%s\033[0m\n' "$colour" "$line"
}

# ---------------------------------------------------------------- stage flair
# STAGE_FX=1 turns on what only makes sense in a real terminal: the pinned trust-ladder bar,
# live wait spinners and the PASS/FAIL marks. Default: on when stdout is a terminal. Off, the
# output is the plain text the tests and the saved evidence read.
if [[ -z "${STAGE_FX:-}" ]]; then
  if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then STAGE_FX=1; else STAGE_FX=0; fi
fi
fx_on() { [[ "${STAGE_FX:-0}" == 1 ]]; }

# The trust ladder, pinned to the top line: the in-story clock and the three rungs with the
# current one lit. _LADDER_ROWS is the terminal height while the bar is pinned (0 = not pinned).
_LADDER_CLOCK="" _LADDER_LEVEL="" _LADDER_ROWS=0 _LADDER_LIVE=0
ladder_text() { # LEVEL CLOCK : the bar, plain or (fx) coloured; at most STAGE_COLS wide
  local level="$1" clock="$2" out="" l plain
  plain="${clock:+$clock }suggest ▸ propose ▸ act"
  if ! fx_on; then printf '%s' "$plain"; return; fi
  [[ -z "$clock" ]] || out="\033[1m$clock\033[0m "
  for l in suggest propose act; do
    if [[ "$l" == "$level" ]]; then out+="\033[7;${C_BOTH}m$l\033[0m"; else out+="\033[2m$l\033[0m"; fi
    [[ "$l" == act ]] || out+="\033[2m ▸ \033[0m"
  done
  printf '%b' "$out"
}
# Each scene is its own process: until this one has a clock or a scene break, leave the bar the
# last scene drew (drawing now would flash it with no clock and no rung lit).
_ladder_draw() {
  ((_LADDER_ROWS > 0)) || return 0
  [[ -n "$_LADDER_CLOCK" ]] || ((_LADDER_LIVE)) || return 0
  printf '\0337\033[1;1H\033[2K%s\0338' "$(ladder_text "$_LADDER_LEVEL" "$_LADDER_CLOCK")"
}
_ladder_unpin() {
  ((_LADDER_ROWS > 0)) || return 0
  printf '\0337\033[1;%sr\0338' "$_LADDER_ROWS"
  _LADDER_ROWS=0
}
# ladder_pin : reserve the top line (scroll region from line 2) and draw the bar; fx only.
ladder_pin() {
  fx_on || return 0
  local rows
  rows="$(tput lines 2>/dev/null || echo 0)"
  ((rows >= 10)) || return 0
  _LADDER_ROWS="$rows"
  printf '\033[2;%sr\033[%s;1H' "$rows" "$rows"
  trap '_ladder_unpin' EXIT
  _ladder_draw
}
ladder_set() { # [LEVEL] [CLOCK] : update the bar; an empty argument keeps the current value
  [[ -z "${1:-}" ]] || _LADDER_LEVEL="$1"
  [[ -z "${2:-}" ]] || _LADDER_CLOCK="$2"
  _ladder_draw
}
ladder_refresh() { # read the level on the tracked branch and redraw (fx only: it is an API call)
  fx_on || return 0
  local level
  level="$(tracked_file "$AUTONOMY_FILE" 2>/dev/null | yq -r '.level // ""' 2>/dev/null || true)"
  ladder_set "$level"
}

# _fx_mark LINE : PASS/FAIL/refused lines with a mark and colour (fx); others unchanged.
_fx_mark() {
  local line="$1" text colour mark
  case "$line" in
    "PASS: "*) mark='✓' colour='1;32' text="${line#PASS: }" ;;
    "PASS "*) mark='✓' colour='1;32' text="${line#PASS }" ;;
    "FAIL: "*) mark='✗' colour='1;31' text="${line#FAIL: }" ;;
    "FAIL "*) mark='✗' colour='1;31' text="${line#FAIL }" ;;
    "refused: "*) mark='✗' colour='1;31' text="$line" ;;
    "handoff: "*) mark='↪' colour='1;33' text="${line#handoff: }" ;;
    *) _plain_beat "$line"; return ;;
  esac
  text="$mark $text"
  printf '\033[%sm%s\033[0m\n' "$colour" "$text"
}

eval "_plain_$(declare -f beat)"
beat() { if fx_on; then _fx_mark "$*"; else _plain_beat "$@"; fi; }

# title_card CLOCK TITLE : an in-character scene opens in a double box (cold open, close).
title_card() {
  local clock="$1" title="$2" inner=$((STAGE_COLS - 4)) l
  for l in "$clock" "$title"; do
    ((${#l} <= inner)) || refuse 1 "title card too long" "title card line over $inner columns: $l"
  done
  _stage_keep "scene: $clock $title"
  _LAST_CUE=""
  ladder_set "" "${clock%% *}"
  printf '\n\033[%sm╔%s╗\n' "$C_SCENE" "$(printf '═%.0s' $(seq $((STAGE_COLS - 2))))"
  printf '║ %-*s ║\n' "$inner" "$clock"
  printf '║ %-*s ║\n' "$inner" "$title"
  printf '╚%s╝\033[0m\n' "$(printf '═%.0s' $(seq $((STAGE_COLS - 2))))"
  _pause
}

# rung_break TITLE : one plain line that starts a rung.
rung_break() { [[ -n "$SCENE" ]] || beat "== $1 =="; }

# ---------------------------------------------------------------- scenes (O31)
OVERNIGHT_VERIFY="${OVERNIGHT_VERIFY:-$DEMO_DIR/../tests/e2e/overnight-verify.sh}"
PROMOTION_PR_SH="${PROMOTION_PR_SH:-$DEMO_DIR/promotion-pr.sh}"

# scene_init NAME : this script is the scene NAME; waits now stop only at the scene pauses.
scene_init() {
  SCENE="$1" _PACE_GATED=1
  ladder_pin
  ladder_refresh
}

_pause() {
  _PAUSE_OPEN=1
  wait
  _PAUSE_OPEN=0
}

scene_break() { # TITLE : the title between two bars, in the scene colour
  _stage_keep "scene: $1"
  _LAST_CUE=""
  _LADDER_LIVE=1
  [[ ! "$1" =~ ^([0-9]{1,2}:[0-9]{2}) ]] || _LADDER_CLOCK="${BASH_REMATCH[1]}"
  _ladder_draw
  printf '\n'
  _bar '═' "$C_SCENE"
  printf '\033[%sm%s\033[0m\n' "$C_SCENE" "$1"
  _bar '═' "$C_SCENE"
  _pause
}

fourth_wall() { # TITLE : an aside, set into a light rule
  _stage_keep "aside: $1"
  _bar '┄' "$C_WALL" "$1"
  _pause
}

_speaker_bar() { # WHO : that character's bar, and remember who has the floor
  case "$1" in
    pe) _bar '━' "$C_PE" "Platform Engineer" ;;
    sre) _bar '━' "$C_SRE" "On-call SRE" ;;
    both) _bar '━' "$C_BOTH" "Both" ;;
  esac
  _LAST_CUE="$1"
}

# cue WHO : WHO has the floor. In a scene a change of speaker draws WHO's bar; in and out of a
# scene the prompt becomes WHO's, so the next typed command is under the right name.
cue() {
  _role_prompt "$1"
  # the same speaker carrying on gets no second bar
  if [[ -n "$SCENE" && "$1" != "${_LAST_CUE:-}" ]]; then _speaker_bar "$1"; fi
}

speaker_beat() { # WHO TOPIC : WHO is pe (the Platform Engineer), sre (the On-call SRE) or both
  local who="$1" topic="${2:-}"
  case "$who" in pe | sre | both) ;; *) die "speaker_beat: WHO must be pe, sre or both, got '$who'" ;; esac
  [[ -z "$SCENE" ]] || _stage_keep "beat: $who: $topic"
  cue "$who"
  _pause
}

# narrate SCENE KEY : see the header. Always returns 0.
# A section header is [key] (the Platform Engineer), [key] sre (the On-call SRE) or [key] both;
# the lines print with that character's prompt. In a scene that character keeps the floor after
# (cue); outside one the prompt in use before is restored.
narrate() {
  local scene="$1" key="$2" file chunk who
  local -a paras=()
  file="${NARRATION_DIR:-$(main_root)/narration}/$scene.txt"
  [[ -r "$file" ]] || return 0
  # one output line per paragraph: the section's lines joined, a blank line between paragraphs
  mapfile -t paras < <(awk -v want="[$key]" '
    function flush() { if (para != "") print para; para = "" }
    { h = $0; sub(/[[:space:]]+$/, "", h) }
    h ~ /^\[[^]]*\]( (pe|sre|both))?$/ {
      if (on) flush()
      t = h; sub(/ (pe|sre|both)$/, "", t); on = (t == want)
      if (on) { w = "pe"; if (h ~ / sre$/) w = "sre"; if (h ~ / both$/) w = "both"; print "@who " w }
      next
    }
    !on { next }
    !NF { flush(); next }
    { l = h; sub(/^[[:space:]]*#[[:space:]]?/, "", l); sub(/^[[:space:]]+/, "", l); para = (para == "" ? l : para " " l) }
    END { if (on) flush() }' "$file")
  ((${#paras[@]} > 1)) || return 0
  who="${paras[0]#@who }"
  paras=("${paras[@]:1}")
  local saved_prompt="${DEMO_PROMPT:-}" saved_plain="$DEMO_PROMPT_PLAIN"
  if [[ -n "$SCENE" ]]; then cue "$who"; else _role_prompt "$who"; fi
  # One paragraph, one line; the terminal wraps it. One Enter per line, after it has typed out
  # (demo-magic's p would wait before and after). Keys pressed while it types are not echoed, so
  # an early Enter never breaks the line on screen.
  stty -echo
  for chunk in "${paras[@]}"; do
    NO_WAIT=true p "# $chunk"
    if [[ "$DEMO_STEP" == line && -n "$SCENE" ]]; then _pause; fi
  done
  stty echo
  if [[ -z "$SCENE" ]]; then
    DEMO_PROMPT="$saved_prompt"
    DEMO_PROMPT_PLAIN="$saved_plain"
  fi
  return 0
}

scene_say() { [[ -z "$SCENE" ]] || narrate "$SCENE" "$1"; } # KEY

# leave_early : a failure branch ends the rung here. On stage a rung script exits 0; inside a
# scene, 10 tells demo-full to stop.
leave_early() { if [[ -n "$SCENE" ]]; then exit 10; fi; exit 0; }

# show_verify RUN_TS : run the after-the-fact verifier, show one short PASS/FAIL line per check
# and keep them in .operator/last-verify for the epilogue. Returns 1 when the verifier fails.
show_verify() {
  local out rc=0 line until
  until="$(date +%s)"
  p "tests/e2e/overnight-verify.sh SINCE=$1 UNTIL=$until"
  out="$("$OVERNIGHT_VERIFY" "SINCE=$1" "UNTIL=$until" 2>&1)" || rc=$?
  mkdir -p "$OPERATOR_STATE"
  : >"$OPERATOR_STATE/last-verify"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    beat "$line"
    printf '%s\n' "$line" >>"$OPERATOR_STATE/last-verify"
  done < <(sed -nE 's/^(PASS|FAIL) ([A-Za-z0-9_-]+).*/\1 \2/p' <<<"$out")
  if ((rc != 0)); then
    beat "verify: FAIL"
    return 1
  fi
}

# promote_to LEVEL PR : verified, merged by people, recorded (the On-call SRE approves as the board).
# With NO_WAIT=true and DEMO_AUTOMERGE_FOR_TEST=1 an open promotion PR is merged here with
# --admin (logged as admin-bypass), which stands in for the board in a run nobody watches.
promote_to() {
  local level="$1" pr="$2" state
  # one line (P23); exit 8 and a refusal line when the PR changed
  shown "scripts/promotion-pr.sh verify $pr" "$PROMOTION_PR_SH" verify "$pr"
  look "Browser, GitHub: the promotion PR, one line" "$(gh pr view "$pr" --repo "$REPO_SLUG" --json url --jq .url)/files"
  scene_say promotion-read # what the diff and the description say
  speaker_beat sre "approves the promotion"
  scene_say board
  state="$(gh pr view "$pr" --repo "$REPO_SLUG" --json state --jq .state 2>/dev/null || true)"
  if [[ "$state" == OPEN ]] && automerge_for_test; then
    shown "scripts/promotion-pr.sh merge $pr --admin" quiet "$PROMOTION_PR_SH" merge "$pr" --admin
  fi
  READY_TIMEOUT_S="${PROMO_WAIT_S:-1800}" until_ready "promotion merged" pr_not_open "$pr"
  pr_state_is "$pr" MERGED || refuse 1 "promotion PR closed" "promotion PR $pr was closed, not merged"
  beat "promotion merged"
  # a direct push to the tracked branch; one line: recorded: board approval | admin bypass
  shown "scripts/promotion-pr.sh record-approval $pr" "$PROMOTION_PR_SH" record-approval "$pr"
  until_ready "$level, approved" level_with_approval "$level"
  ladder_set "$level"
}

# typed COMMAND : demo-magic's pe. The typed commands run through demo-magic's eval in this
# shell. Under `make demo-rung-N` a nested make would print "make[1]: Entering directory ..."
# lines; this make leaves them out.
make() { command make "$@" --no-print-directory; }

typed() {
  pe "$1"
  [[ "$1" != *demote* ]] || ladder_refresh
}

# shown DISPLAY CMD... : what the script does for the speakers, on screen. DISPLAY is typed at the
# prompt (the real command as the audience reads it), then CMD runs.
shown() {
  local display="$1"
  shift
  p "$display"
  "$@"
}

# note TEXT : one plain line, "› TEXT", saying what happens out of view.
note() {
  local text="› $*"
  if fx_on; then printf '\033[%sm%s\033[0m\n' "$C_WALL" "$text"; else printf '%s\n' "$text"; fi
}

# look WHERE [URL] : point the audience at the screen that matters now ("▶ Browser, Argo CD:
# checkout"), then open URL, if given. The Argo CD and Grafana tabs are open all talk: a look at
# them names the place and opens nothing.
look() {
  local text="▶ $1"
  _stage_keep "look: $1"
  if fx_on; then printf '\033[%sm%s\033[0m\n' "$C_LOOK" "$text"; else printf '%s\n' "$text"; fi
  [[ -z "${2:-}" ]] || open_tab "$2"
}

# until_ready DESC CMD... : one line, then wait for CMD to succeed (a real condition, never a
# sleep). READY_TIMEOUT_S sets the limit (default 300); READY_NOTE replaces the "waiting:" line
# with a plain "# NOTE" for a long wait ("# canary, about 60s"). Exit 4 on a timeout.
until_ready() {
  local desc="$1"
  shift
  if fx_on; then
    [[ -z "${READY_NOTE:-}" ]] || beat "# $READY_NOTE"
    _fx_wait "$desc" "${READY_TIMEOUT_S:-300}" "$@"
    return
  fi
  if [[ -n "${READY_NOTE:-}" ]]; then beat "# $READY_NOTE"; else beat "waiting: $desc"; fi
  stage_wait "$desc" "${READY_TIMEOUT_S:-300}" "$@"
}

# _fx_wait DESC TIMEOUT CMD... : until_ready in a terminal: a spinner and the seconds so far,
# checked every 2 s, then one dim line with the time it took. Exit 4 on a timeout, as stage_wait.
_fx_wait() {
  local desc="$1" timeout="$2" frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 start=$SECONDS next=0 label
  shift 2
  label="${desc:0:$((STAGE_COLS - 8))}"
  while true; do
    if ((SECONDS >= next)); then
      if "$@" >/dev/null 2>&1; then
        printf '\r\033[2K\033[2m· %s %ss\033[0m\n' "$label" "$((SECONDS - start))"
        return 0
      fi
      if ((SECONDS - start >= timeout)); then
        printf '\r\033[2K'
        printf 'timeout: %s\n' "${desc:0:21}" >&2
        return 4
      fi
      next=$((SECONDS + 2))
    fi
    printf '\r\033[2K\033[%sm%s\033[0m %s %ss' "$C_BOTH" "${frames:i++%10:1}" "$label" "$((SECONDS - start))"
    sleep 0.15
  done
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
# open_tab URL : hand the URL to the browser (DEMO_OPEN, see the header). Tabs open in call order.
# Only pages that are new on stage are opened (a commit, a comment, a PR, its checks, a file).
# The Argo CD and Grafana tabs stay open in the browser all talk, so no scene opens them.
default_opener() { if [[ "$(uname -s)" == Darwin ]]; then echo open; else echo xdg-open; fi; }
open_tab() {
  local -a opener
  read -r -a opener <<<"${DEMO_OPEN:-$(default_opener)}"
  if ((${#opener[@]} == 0)) || ! command -v "${opener[0]}" >/dev/null 2>&1; then
    beat "no browser opener"
    return 0
  fi
  "${opener[@]}" "$1" >/dev/null 2>&1 || true
}

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

level_with_approval() { tracked_level_is "$1" && [[ -n "$(autonomy_approved_by)" ]]; } # LEVEL

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

# require_fix_pr : after unhappy_outcome, an outcome that is still not a fix PR (an RCA comment
# where rungs 2 and 3 expect a PR) ends the rung: a FAIL under NO_WAIT=true, else leave_early.
require_fix_pr() {
  [[ "$OUT_KIND" != pr ]] || return 0
  beat "no fix PR, only a comment"
  open_tab "$OUT_URL"
  [[ "$NO_WAIT" == true ]] && exit 1
  leave_early
}

# human_fix : the On-call SRE's beat, then the On-call SRE makes the human fix (make fix, one
# pushed: line), says what it did (narration key after-fix) and waits until Healthy. The prompt
# is the SRE's: it follows the bar (cue).
human_fix() {
  speaker_beat sre "before the human fix"
  typed "make fix"
  scene_say after-fix
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
  if reject_for_test; then note "test hook: closes the fix PR"; else note "test hook: merges the fix PR"; fi
  (
    local pr
    wait_for "the bot's fix PR" 600 have_agent_pr_since "$t0" checkout
    pr="$(agent_prs_since "$t0" checkout | head -n1 | jq -r .number)"
    if reject_for_test; then
      gh pr close "$pr" --repo "$REPO_SLUG" --comment "Rejected by the NO_WAIT test hook." >/dev/null
    else
      wait_for "policy-check on PR $pr" 600 pr_policy_check_done "$pr"
      [[ "$(pr_policy_check_conclusion "$pr")" == success ]]
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
