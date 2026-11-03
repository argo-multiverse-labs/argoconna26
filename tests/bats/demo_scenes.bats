#!/usr/bin/env bats
# Tests for the scene scripts, demo-full and the narration interface (Task 6.4a, O31).
# Same stubs as demo_rungs.bats (tests/bats/demo_helpers.bash): nothing touches a cluster,
# GitHub or systemd.

load helpers
load demo_helpers

# The keys each scene script (and the rung body it runs) asks for, for the narration fixture.
declare -gA SCENE_KEYS=(
  [cold-open]="mandate bolted-on page what-changed slack"
  [prologue]="intro timeline golden-path data cdevents rfc"
  [scene-1]="intro push gate wait-teach rca fix resolved"
  [scene-2]="intro promotion board incident-again identity fix-pr review merged rejected demote act-offstage"
  [scene-3]="intro board policy teach pr policy-pass merged healthy verify"
  [epilogue]="panel verifier real real-list simulated valve safe"
  [close]="timeline slack drop repo"
)

# write_narration DIR : every key of every scene, one long Platform Engineer line and one SRE placeholder
write_narration() {
  local dir="$1" scene key
  mkdir -p "$dir"
  for scene in "${!SCENE_KEYS[@]}"; do
    : >"$dir/$scene.txt"
    for key in ${SCENE_KEYS[$scene]}; do
      printf '[%s]\n# The engineer says something fairly long about %s in %s, in plain words.\n\n# [SRE: %s beat topic]\n' \
        "$key" "$key" "$scene" "$key" >>"$dir/$scene.txt"
    done
  done
}

# probe : a script that does one of each kind of scene stop and several things that must not stop
write_probe() {
  cat >"$BATS_TEST_TMPDIR/probe.sh" <<EOF
. '$REPO_ROOT/scripts/demo-common.sh'
scene_init probe
scene_break "A"
typed "echo hi"
p "# a comment"
scene_say nokey
until_ready "x" true
fourth_wall "B"
speaker_beat pe "topic"
typed "echo two"
wait_never_asked=1
EOF
  # 20 blank lines are Enter presses; UNREAD ends the file
  { for _ in $(seq 20); do echo; done; echo UNREAD; } >"$BATS_TEST_TMPDIR/stdin.txt"
}

# run_probe : run the probe with stdin from a file and count the lines it left unread
run_probe() {
  cd "$FIXTURE"
  { bash "$BATS_TEST_TMPDIR/probe.sh" >"$BATS_TEST_TMPDIR/probe.out" 2>&1; cat >"$BATS_TEST_TMPDIR/remaining.txt"; } <"$BATS_TEST_TMPDIR/stdin.txt"
  PROBE_LEFT="$(wc -l <"$BATS_TEST_TMPDIR/remaining.txt")"
}

scene() { # NAME : run the scene script from the fixture, merged output
  (cd "$FIXTURE" && "$REPO_ROOT/scripts/demo-$1.sh")
}

setup() {
  ORIG_PATH="$PATH" # demo_setup puts a stub make first on PATH; the Makefile tests need the real one
  demo_setup suggest
  export NARRATION_DIR="$BATS_TEST_TMPDIR/narration"
  write_narration "$NARRATION_DIR"
}

# ------------------------------------------------------------------ demo-full

@test "demo-full runs the scenes in order with no reset between them" {
  fake="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$fake"
  for s in cold-open prologue scene-1 scene-2 scene-3 epilogue close; do
    printf '#!/usr/bin/env bash\necho "scene %s" >>"$LOG"\n' "$s" >"$fake/demo-$s.sh"
    chmod +x "$fake/demo-$s.sh"
  done
  DEMO_SCENES_DIR="$fake" run "$REPO_ROOT/scripts/demo-full.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG")" = "scene cold-open
scene prologue
scene scene-1
scene scene-2
scene scene-3
scene epilogue
scene close" ]
  ! grep -q 'reset' "$LOG"
  # no reset is run (the resume hint only prints the make target for the operator)
  ! grep -v '^#' "$REPO_ROOT/scripts/demo-full.sh" | grep -v "printf 'next: make reset-to-scene" | grep -q 'reset'
}

@test "demo-full stops at the first scene that fails and returns its code" {
  fake="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$fake"
  for s in cold-open prologue scene-1 scene-2 scene-3 epilogue close; do
    printf '#!/usr/bin/env bash\necho "scene %s" >>"$LOG"\n[[ %s != scene-1 ]] || exit 10\n' "$s" "$s" >"$fake/demo-$s.sh"
    chmod +x "$fake/demo-$s.sh"
  done
  DEMO_SCENES_DIR="$fake" run "$REPO_ROOT/scripts/demo-full.sh"
  [ "$status" -eq 10 ]
  [[ "$output" == *"stopped: scene-1 (exit 10)"* ]]
  ! grep -q 'scene scene-2' "$LOG"
}

# fake_scenes_stop_at SCENE CODE : fake scene scripts; SCENE exits CODE.
fake_scenes_stop_at() {
  fake="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$fake"
  for s in cold-open prologue scene-1 scene-2 scene-3 epilogue close; do
    printf '#!/usr/bin/env bash\n[[ %s != %s ]] || exit %d\n' "$s" "$1" "$2" >"$fake/demo-$s.sh"
    chmod +x "$fake/demo-$s.sh"
  done
}

@test "demo-full says how to carry on after a stop in scene 1 or 2" {
  fake_scenes_stop_at scene-1 10
  DEMO_SCENES_DIR="$fake" run "$REPO_ROOT/scripts/demo-full.sh"
  [ "$status" -eq 10 ]
  [[ "$output" == *"next: make reset-to-scene-2"* ]]
  [[ "$output" == *"then: make demo-scene-2"* ]]
  fake_scenes_stop_at scene-2 1
  DEMO_SCENES_DIR="$fake" run "$REPO_ROOT/scripts/demo-full.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"next: make reset-to-scene-3"* ]]
  [[ "$output" == *"then: make demo-scene-3"* ]]
}

@test "demo-full says to run the epilogue and close after a stop in scene 3" {
  fake_scenes_stop_at scene-3 6
  DEMO_SCENES_DIR="$fake" run "$REPO_ROOT/scripts/demo-full.sh"
  [ "$status" -eq 6 ]
  [[ "$output" == *"next: make demo-epilogue"* ]]
  [[ "$output" == *"then: make demo-close"* ]]
  ! [[ "$output" == *"reset-to-scene"* ]]
  fake_scenes_stop_at epilogue 1
  DEMO_SCENES_DIR="$fake" run "$REPO_ROOT/scripts/demo-full.sh"
  [[ "$output" == *"next: make demo-close"* ]]
}

@test "demo-full resume lines fit the stage pane" {
  local s line
  for s in scene-1 scene-2 scene-3 epilogue; do
    fake_scenes_stop_at "$s" 10
    DEMO_SCENES_DIR="$fake" run "$REPO_ROOT/scripts/demo-full.sh"
    while IFS= read -r line; do
      [ "${#line}" -le 30 ] || { echo "too long: $line"; return 1; }
    done <<<"$output"
  done
}

# ------------------------------------------------------------------ pace

@test "talk pace stops only at scene_break, fourth_wall and beat" {
  write_probe
  export NO_WAIT=false DEMO_PACE=talk
  run_probe
  # three Enters were read (scene_break, fourth_wall, speaker_beat); UNREAD is still there
  [ "$PROBE_LEFT" -eq 18 ]
  grep -qx UNREAD "$BATS_TEST_TMPDIR/remaining.txt"
}

@test "auto pace never reads stdin" {
  write_probe
  export NO_WAIT=false DEMO_PACE=auto
  run_probe
  [ "$PROBE_LEFT" -eq 21 ]
  export NO_WAIT=true DEMO_PACE=talk # and NO_WAIT=true never reads either
  run_probe
  [ "$PROBE_LEFT" -eq 21 ]
  DEMO_PACE=fast run bash -c ". '$REPO_ROOT/scripts/demo-common.sh'"
  [ "$status" -ne 0 ]
}

# ------------------------------------------------------------------ narration

@test "narration missing prints nothing and does not fail" {
  cd "$FIXTURE"
  run bash -c ". '$REPO_ROOT/scripts/demo-common.sh'; NARRATION_DIR='$BATS_TEST_TMPDIR/none' narrate scene-1 push; echo rc=\$?"
  [ "$status" -eq 0 ]
  [ "$output" = "rc=0" ]
  # a file without the key
  run bash -c ". '$REPO_ROOT/scripts/demo-common.sh'; narrate scene-1 not-a-key; echo rc=\$?"
  [ "$status" -eq 0 ]
  [ "$output" = "rc=0" ]
  # a scene run with no narration directory at all still works
  happy_rung1() { seed_rung1; set_comment "$(rca_body)"; }
  happy_rung1
  NARRATION_DIR="$BATS_TEST_TMPDIR/none" run scene scene-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"RCA: comment posted"* ]]
}

@test "narrate prints one section, in the p style, folded to the stage" {
  cd "$FIXTURE"
  run bash -c ". '$REPO_ROOT/scripts/demo-common.sh'; narrate scene-1 push"
  [ "$status" -eq 0 ]
  out="$(strip_ansi "$output")"
  [[ "$out" == *"# The engineer says"* ]]
  [[ "$out" == *"[SRE: push beat"* ]]
  [[ "$out" != *"gate"* ]] # the next section is not printed
  assert_fits "$output"
}

@test "speaker cues name the talk's characters, never a speaker" {
  cd "$FIXTURE"
  for who in pe sre both; do
    run bash -c "SCENE=x DEMO_PACE=auto NO_WAIT=true . '$REPO_ROOT/scripts/demo-common.sh'; SCENE=x; speaker_beat $who t"
    [ "$status" -eq 0 ]
  done
  run bash -c "SCENE=x NO_WAIT=true . '$REPO_ROOT/scripts/demo-common.sh'; SCENE=x; speaker_beat pe t; speaker_beat sre t"
  [[ "$(strip_ansi "$output")" == *"━━ Platform Engineer"*"━━ On-call SRE"* ]]
  run bash -c "NO_WAIT=true . '$REPO_ROOT/scripts/demo-common.sh'; speaker_beat luke t"
  [ "$status" -ne 0 ]
  # every cue in the scripts is one of the three
  ! grep -hoE '^[[:space:]]*speaker_beat [a-z]+' "$REPO_ROOT"/scripts/demo-*.sh | grep -vE 'speaker_beat (pe|sre|both)$'
}

# The keys that are the On-call SRE's (a placeholder only); every other key is the Platform
# Engineer's. Mirrors the local narration.
declare -gA SRE_KEYS=(
  [cold-open]="page what-changed"
  [prologue]="data"
  [scene-1]="wait-teach"
  [scene-2]="board review rejected"
  [scene-3]="board teach"
  [epilogue]="real valve"
  [close]="slack drop"
)

# write_role_narration DIR : each key is one short line, "# PEline-KEY" or "# [SRE: KEY]".
write_role_narration() {
  local dir="$1" scene key
  mkdir -p "$dir"
  for scene in "${!SCENE_KEYS[@]}"; do
    : >"$dir/$scene.txt"
    for key in ${SCENE_KEYS[$scene]}; do
      if [[ " ${SRE_KEYS[$scene]:-} " == *" $key "* ]]; then
        printf '[%s] sre\n# [SRE: %s]\n\n' "$key" "$key" >>"$dir/$scene.txt"
      else
        printf '[%s]\n# PEline-%s\n\n' "$key" "$key" >>"$dir/$scene.txt"
      fi
    done
  done
}

# cues_ok TEXT : every SRE placeholder follows an On-call SRE or Both cue, and every Platform
# Engineer line follows a Platform Engineer or Both cue (or no cue yet in that text).
cues_ok() {
  local line cue="" bad=0
  while IFS= read -r line; do
    case "$line" in
      *"━━ Platform Engineer"*) cue=pe ;;
      *"━━ On-call SRE"*) cue=sre ;;
      *"━━ Both"*) cue=both ;;
      *"[SRE: "*) [[ "$cue" == sre || "$cue" == both ]] || { echo "SRE line under '$cue': $line"; bad=1; } ;;
      *PEline-*) [[ -z "$cue" || "$cue" == pe || "$cue" == both ]] || { echo "PE line under '$cue': $line"; bad=1; } ;;
    esac
  done <<<"$1"
  return "$bad"
}

@test "the reject branch: the SRE's placeholder, then the Platform Engineer's cue and callback" {
  demo_setup suggest
  set_prs "$(fix_body propose)"
  export DEMO_REJECT_FOR_TEST=1 NARRATION_DIR="$BATS_TEST_TMPDIR/roles"
  write_role_narration "$NARRATION_DIR"
  run scene scene-2
  [ "$status" -eq 0 ]
  # from the review's hand-over to the end
  r="$(grep -n 'SRE: review\]' <<<"$output" | head -n1 | cut -d: -f1)"
  c="$(head -n "$r" <<<"$output" | grep -n '━━ On-call SRE' | tail -n1 | cut -d: -f1)"
  [ -n "$c" ]
  window="$(tail -n "+$c" <<<"$output")"
  [[ "$window" == *"rejected: demoting"* ]]
  [[ "$window" == *"[SRE: rejected]"* ]]
  [[ "$window" == *"PEline-demote"* ]]
  cues_ok "$window"
}

@test "epilogue and close cue each speaker before their lines" {
  demo_setup act
  export NARRATION_DIR="$BATS_TEST_TMPDIR/roles"
  write_role_narration "$NARRATION_DIR"
  run scene epilogue
  [ "$status" -eq 0 ]
  [[ "$output" == *"[SRE: real]"* && "$output" == *"PEline-real-list"* ]]
  cues_ok "$output"
  run scene close
  [ "$status" -eq 0 ]
  cues_ok "$output"
  # the joint landing line is cued for both
  both="$(grep -n '━━ Both' <<<"$output" | head -n1 | cut -d: -f1)"
  drop="$(grep -n 'SRE: drop' <<<"$output" | head -n1 | cut -d: -f1)"
  [ -n "$both" ] && [ -n "$drop" ] && [ "$both" -lt "$drop" ]
}

@test "scene 3 puts the policy on screen before the job runs" {
  demo_setup act
  set_prs "$(fix_body act)"
  echo "$BOT" >"$ST/auto-merge-by"
  run scene scene-3
  [ "$status" -eq 0 ]
  p="$(grep -n '^open .*/blob/.*/policy/autofix.rego$' "$LOG" | head -n1 | cut -d: -f1)"
  n="$(grep -n '^make night' "$LOG" | head -n1 | cut -d: -f1)"
  [ -n "$p" ] && [ -n "$n" ] && [ "$p" -lt "$n" ]
}

@test "narrate prints an sre-tagged section with the SRE prompt, then restores the prompt" {
  cd "$FIXTURE"
  mkdir -p "$BATS_TEST_TMPDIR/tag"
  printf '[a] sre\n# the SRE says this\n\n[b]\n# the engineer says this\n' >"$BATS_TEST_TMPDIR/tag/scene-1.txt"
  run bash -c ". '$REPO_ROOT/scripts/demo-common.sh'; as_platform_engineer; NARRATION_DIR='$BATS_TEST_TMPDIR/tag'; narrate scene-1 a; narrate scene-1 b; p '# after'"
  [ "$status" -eq 0 ]
  out="$(strip_ansi "$output")"
  [[ "$out" == *"[SRE]\$ # the SRE says this"* ]]
  [[ "$out" == *"[PE]\$ # the engineer says this"* ]]
  [[ "$out" == *"[PE]\$ # after"* ]]
  [[ "$out" != *"the engineer says this"*"[SRE]\$"* ]]
  assert_fits "$output"
}

@test "each character has a bold, colour-coded prompt, and a cue is a bar in that colour" {
  cd "$FIXTURE"
  run bash -c "SCENE=x NO_WAIT=true . '$REPO_ROOT/scripts/demo-common.sh'; SCENE=x; as_platform_engineer; p '# a'; as_oncall_sre; p '# b'; as_both; p '# c'; speaker_beat pe t; speaker_beat sre t; speaker_beat both t"
  [ "$status" -eq 0 ]
  out="$(strip_ansi "$output")"
  [[ "$out" == *"[PE]\$ # a"*"[SRE]\$ # b"*"[ALL]\$ # c"* ]]
  # the three prompts use three different bold colours
  pe_c="$(grep -o $'\e\[1;[0-9]*m\[PE\]' <<<"$output" | head -n1)"
  sre_c="$(grep -o $'\e\[1;[0-9]*m\[SRE\]' <<<"$output" | head -n1)"
  all_c="$(grep -o $'\e\[1;[0-9]*m\[ALL\]' <<<"$output" | head -n1)"
  [ -n "$pe_c" ] && [ -n "$sre_c" ] && [ -n "$all_c" ]
  [ "${pe_c%%m*}" != "${sre_c%%m*}" ] && [ "${sre_c%%m*}" != "${all_c%%m*}" ]
  # each cue is a full-width bar: exactly STAGE_COLS wide
  for name in "Platform Engineer" "On-call SRE" "Both"; do
    line="$(grep "━━ $name " <<<"$out" | head -n1)"
    [ "${#line}" -eq "$STAGE_COLS" ]
  done
  assert_fits "$output"
}

@test "a second cue for the same speaker draws no second bar; a new scene shows it again" {
  cd "$FIXTURE"
  run bash -c "SCENE=x NO_WAIT=true . '$REPO_ROOT/scripts/demo-common.sh'; SCENE=x; speaker_beat sre a; speaker_beat sre b; speaker_beat pe c; speaker_beat sre d; scene_break T; speaker_beat sre e"
  [ "$status" -eq 0 ]
  [ "$(grep -c '━━ On-call SRE' <<<"$(strip_ansi "$output")")" -eq 3 ]
}

@test "a scene break is a title between two full-width bars, and the theme picks the colours" {
  cd "$FIXTURE"
  run bash -c "NO_WAIT=true . '$REPO_ROOT/scripts/demo-common.sh'; scene_break '2:19 Look'; fourth_wall 'Aside'"
  [ "$status" -eq 0 ]
  out="$(strip_ansi "$output")"
  bar="$(printf '═%.0s' $(seq "$STAGE_COLS"))"
  [ "$(grep -c "^$bar\$" <<<"$out")" -eq 2 ]
  [[ "$out" == *"$bar"*"2:19 Look"*"$bar"* ]]
  [[ "$out" == *"Aside"* ]]
  assert_fits "$output"
  light="$output"
  run bash -c "DEMO_THEME=dark NO_WAIT=true . '$REPO_ROOT/scripts/demo-common.sh'; scene_break '2:19 Look'"
  [ "$status" -eq 0 ]
  [ "$(grep -m1 -o $'\e\[[0-9;]*m═' <<<"$light")" != "$(grep -m1 -o $'\e\[[0-9;]*m═' <<<"$output")" ]
  run bash -c "DEMO_THEME=neon NO_WAIT=true . '$REPO_ROOT/scripts/demo-common.sh'"
  [ "$status" -ne 0 ]
}

# speakers_ok DIR : every SRE key (SRE_KEYS) is tagged sre, no other key is, no SRE placeholder is
# left, and no speaker's real name appears (O35, O36).
speakers_ok() {
  local dir="$1" scene key bad=0
  for scene in "${!SRE_KEYS[@]}"; do
    [[ -r "$dir/$scene.txt" ]] || continue
    for key in ${SRE_KEYS[$scene]}; do
      grep -qxE "\[$key\] (sre|both)" "$dir/$scene.txt" || { echo "$scene [$key] not tagged sre"; bad=1; }
    done
  done
  while IFS= read -r line; do
    key="${line#*[}"; key="${key%%]*}"; scene="$(basename "${line%%:*}" .txt)"
    [[ " ${SRE_KEYS[$scene]:-} " == *" $key "* ]] || { echo "$scene [$key] tagged sre but is not an SRE key"; bad=1; }
  done < <(grep -HxE '\[[^]]+\] (sre|both)' "$dir"/*.txt 2>/dev/null)
  ! grep -n '\[SRE: ' "$dir"/*.txt || bad=1
  ! grep -niE 'luke|hilliary' "$dir"/*.txt || bad=1
  # one stage line per narration line: no line folds under its speaker's prompt
  local over
  over="$(awk -v cols="$STAGE_COLS" '/^\[[^]]*\]( (pe|sre|both))?$/ { p = ($0 ~ / (sre|both)$/) ? 7 : 6; on = 1; next }
    FNR == 1 { on = 0 } on && /^# / { t = substr($0, 3); if (length(t) > cols - p - 2) print FILENAME ": " t }' "$dir"/*.txt)"
  [[ -z "$over" ]] || { echo "$over"; bad=1; }
  return "$bad"
}

@test "the real narration tags each SRE section, has no placeholders, and names no speaker" {
  main="$(dirname "$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)")"
  [[ -d "$main/narration" ]] || skip "no local narration"
  speakers_ok "$main/narration"
  # and the check itself catches a missing tag and a name
  mkdir -p "$BATS_TEST_TMPDIR/bad"
  printf '[page]\n# words\n' >"$BATS_TEST_TMPDIR/bad/cold-open.txt"
  run speakers_ok "$BATS_TEST_TMPDIR/bad"
  [ "$status" -ne 0 ]
  printf '[page] sre\n# Luke said\n' >"$BATS_TEST_TMPDIR/bad/cold-open.txt"
  run speakers_ok "$BATS_TEST_TMPDIR/bad"
  [ "$status" -ne 0 ]
}

@test "the scripts never write narration into Git" {
  ! grep -rn 'narration' "$REPO_ROOT/.gitignore"
  ! grep -rn 'narration' "$REPO_ROOT/scripts/demo-common.sh" | grep -q 'git add'
}

# ------------------------------------------------------------------ output

@test "every printed line fits STAGE_COLS" {
  seed_rung1
  set_comment "$(rca_body)"
  run scene cold-open
  [ "$status" -eq 0 ]
  assert_fits "$output"
  [[ "$output" == *"bridge: up"* ]]
  run scene prologue
  [ "$status" -eq 0 ]
  assert_fits "$output"
  [[ "$output" == *"Argo CD: all green"* ]]
  run scene scene-1
  [ "$status" -eq 0 ]
  assert_fits "$output"
  [[ "$output" == *"[SRE:"* ]]
  [[ "$(strip_ansi "$output")" == *"2:19 Look, don't touch"* ]]
  ! grep -q 'cause:' <<<"$output"
  ! grep -qE '[0-9a-f]{40}' <<<"$output"

  demo_setup suggest
  set_prs "$(fix_body propose)"
  export DEMO_AUTOMERGE_FOR_TEST=1
  run scene scene-2
  [ "$status" -eq 0 ]
  assert_fits "$output"
  [[ "$output" == *"promotion PR open"* ]] # the offstage act promotion
  ! grep -q 'cause:' <<<"$output"
  ! grep -qE '[0-9a-f]{40}' <<<"$output"

  demo_setup act
  set_prs "$(fix_body act)"
  echo "$BOT" >"$ST/auto-merge-by"
  run scene scene-3
  [ "$status" -eq 0 ]
  assert_fits "$output"
  [[ "$output" == *"PASS everything"* ]] # the verifier's short lines
  ! grep -q 'cause:' <<<"$output"
  ! grep -qE '[0-9a-f]{40}' <<<"$output"

  run scene epilogue
  [ "$status" -eq 0 ]
  assert_fits "$output"
  [[ "$output" == *"autonomy: suggest"* ]]
  [[ "$output" == *"PASS everything"* ]] # replayed from scene 3
  run scene close
  [ "$status" -eq 0 ]
  assert_fits "$output"
  [[ "$output" == *"$SLUG"* || "$output" == *"argoconna26"* ]]
}

@test "a scene that ends on handoff leaves early, exit 10, so demo-full stops" {
  seed_rung1
  set_comment "$(handoff_body)"
  export NO_WAIT=false
  cd "$FIXTURE"
  run bash -c "yes '' | '$REPO_ROOT/scripts/demo-scene-1.sh'"
  [ "$status" -eq 10 ]
  [[ "$output" == *"handoff: cut to clip"* ]]
  ! grep -q '^make fix' "$LOG"
}

# ------------------------------------------------------------------ scene 3

@test "scene 3 opens the act promotion it needs when scene 2 left none" {
  demo_setup propose
  set_prs "$(fix_body act)"
  echo "$BOT" >"$ST/auto-merge-by"
  jq -n '{number: 12, state: "MERGED", url: "https://github.com/x/y/pull/12"}' >"$ST/pr-12.json"
  export DEMO_AUTOMERGE_FOR_TEST=1
  [ ! -e "$FIXTURE/.operator/promotion-act" ]
  run scene scene-3
  [ "$status" -eq 0 ]
  mapfile -t calls < <(grep -E '^(promo|make night)' "$LOG" | awk '{print $1, $2, $3}')
  [ "${calls[0]}" = "promo ensure act" ]
  [ "${calls[1]}" = "promo verify 13" ]
  [ "${calls[2]}" = "promo merge 13" ]
  [ "${calls[3]}" = "promo record-approval 13" ]
  [ "${calls[4]}" = "make night --no-print-directory" ]
  [[ "$output" == *"promotion merged"* ]]
}

@test "scene 3 teaches under the make night wait, after the job starts (O32)" {
  demo_setup propose
  set_prs "$(fix_body act)"
  echo "$BOT" >"$ST/auto-merge-by"
  jq -n '{number: 12, state: "MERGED", url: "https://github.com/x/y/pull/12"}' >"$ST/pr-12.json"
  export DEMO_AUTOMERGE_FOR_TEST=1
  write_narration "$BATS_TEST_TMPDIR/text"
  export NARRATION_DIR="$BATS_TEST_TMPDIR/text"
  run scene scene-3
  [ "$status" -eq 0 ]
  night="$(grep -n 'make night' <<<"$output" | head -n1 | cut -d: -f1)"
  teach="$(grep -n 'SRE: teach' <<<"$output" | head -n1 | cut -d: -f1)"
  [ -n "$night" ] && [ -n "$teach" ]
  [ "$teach" -gt "$night" ]
}

@test "scene 3 uses the open act promotion scene 2 left, without opening another" {
  demo_setup propose
  set_prs "$(fix_body act)"
  echo "$BOT" >"$ST/auto-merge-by"
  jq -n '{number: 13, state: "OPEN", url: "https://github.com/x/y/pull/13"}' >"$ST/pr-13.json"
  printf 'pr=13\nhead=x\nbranch=promote-x\n' >"$FIXTURE/.operator/promotion-act"
  export DEMO_AUTOMERGE_FOR_TEST=1
  run scene scene-3
  [ "$status" -eq 0 ]
  ! grep -q '^promo ensure' "$LOG"
  grep -q '^promo verify 13' "$LOG"
}

@test "scene 3 below propose refuses with exit 6 and does not run make night" {
  demo_setup suggest
  run scene scene-3
  [ "$status" -eq 6 ]
  [[ "$output" == *"refused: below propose; clip"* ]]
  ! grep -q '^make night' "$LOG"
}

@test "scene 2 opens no act promotion after a reject and demote" {
  demo_setup suggest
  set_prs "$(fix_body propose)"
  export DEMO_REJECT_FOR_TEST=1
  run scene scene-2
  [ "$status" -eq 0 ]
  [[ "$output" == *"no act promotion yet"* ]]
  ! grep -q '^promo ensure act' "$LOG"
}

# ------------------------------------------------------------------ make

@test "reset-to-scene-N calls the matching reset" {
  run env PATH="$ORIG_PATH" make -n --no-print-directory -C "$REPO_ROOT" reset-to-scene-0
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/reset.sh demo"* ]]
  for n in 1 2 3; do
    run env PATH="$ORIG_PATH" make -n --no-print-directory -C "$REPO_ROOT" "reset-to-scene-$n"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scripts/reset.sh $n"* ]]
  done
}

@test "make targets run the scene scripts" {
  for t in cold-open prologue scene-1 scene-2 scene-3 epilogue close full; do
    run env PATH="$ORIG_PATH" make -n --no-print-directory -C "$REPO_ROOT" "demo-$t"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scripts/demo-$t.sh" ]]
  done
}

@test "record-scene-N and record-full record the matching target" {
  for t in scene-1 scene-2 scene-3 full; do
    run env PATH="$ORIG_PATH" make -n --no-print-directory -C "$REPO_ROOT" "record-$t"
    [ "$status" -eq 0 ]
    [[ "$output" == *"asciinema rec"* ]]
    [[ "$output" == *"$t-\$(date"* || "$output" == *"/$t-\$\$(date"* || "$output" == *"/$t-"* ]]
    [[ "$output" == *"demo-$t"* ]]
  done
  run env PATH="$ORIG_PATH" make -n --no-print-directory -C "$REPO_ROOT" record-rung-2
  [[ "$output" == *"rung-2-"* && "$output" == *"demo-rung-2"* ]]
}

# ------------------------------------------------------------------ stage flair (STAGE_FX)
fx() { bash -c "export STAGE_FX=1; SCENE=x NO_WAIT=true . '$REPO_ROOT/scripts/demo-common.sh'; SCENE=x; $1"; }

@test "off a terminal the flair is off and the output stays plain" {
  cd "$FIXTURE"
  run bash -c "NO_WAIT=true . '$REPO_ROOT/scripts/demo-common.sh' </dev/null >/dev/null; . '$REPO_ROOT/scripts/demo-common.sh'; echo fx=\$STAGE_FX; check ok true; until_ready thing true" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"fx=0"* && "$output" == *"PASS: ok"* && "$output" == *"waiting: thing"* ]]
}

@test "fx: PASS, FAIL, refused and handoff lines get a mark and a colour, and still fit" {
  cd "$FIXTURE"
  run fx "beat 'PASS: approver is a role'; beat 'PASS overnight-verify-rung3'; beat 'FAIL policy'; beat 'refused: low confidence'; beat 'handoff: cut to clip'; beat 'plain line'"
  [ "$status" -eq 0 ]
  out="$(strip_ansi "$output")"
  [[ "$out" == *"✓ approver is a role"* && "$out" == *"✓ overnight-verify-rung3"* ]]
  [[ "$out" == *"✗ policy"* && "$out" == *"✗ refused: low confidence"* && "$out" == *"↪ cut to clip"* ]]
  [[ "$out" == *"plain line"* ]]
  grep -q $'\e\\[1;32m✓' <<<"$output"
  grep -q $'\e\\[1;31m✗' <<<"$output"
  assert_fits "$output"
}

@test "fx: until_ready shows a spinner with seconds, then one line with the time it took" {
  cd "$FIXTURE"
  printf 0 >"$BATS_TEST_TMPDIR/n"
  run fx "ok_on_second() { n=\$(cat '$BATS_TEST_TMPDIR/n'); echo \$((n + 1)) >'$BATS_TEST_TMPDIR/n'; [ \$n -ge 1 ]; }; until_ready 'agent outcome' ok_on_second"
  [ "$status" -eq 0 ]
  out="$(strip_ansi "$output")"
  [[ "$out" == *"⠋ agent outcome 0s"* ]]
  last="$(tr '\r' '\n' <<<"$out" | grep -v '^$' | tail -n1)"
  [[ "$last" =~ ^·\ agent\ outcome\ [0-9]+s$ ]]
  [ "${#last}" -le "$STAGE_COLS" ]
}

@test "fx: until_ready times out with exit 4 and a timeout line" {
  cd "$FIXTURE"
  run fx "READY_TIMEOUT_S=0 until_ready 'never' false"
  [ "$status" -eq 4 ]
  [[ "$output" == *"timeout: never"* ]]
}

@test "the ladder bar names the three rungs, lights the current one, and fits" {
  cd "$FIXTURE"
  run bash -c "export STAGE_FX=0; NO_WAIT=true . '$REPO_ROOT/scripts/demo-common.sh'; ladder_text propose 12:59"
  [ "$output" = "12:59 suggest ▸ propose ▸ act" ]
  [ "${#output}" -le "$STAGE_COLS" ]
  run fx "ladder_text propose 2:24"
  [[ "$(strip_ansi "$output")" == "2:24 suggest ▸ propose ▸ act" ]]
  grep -q $'\e\\[7;[0-9;]*mpropose' <<<"$output"
  ! grep -q $'\e\\[7;[0-9;]*msuggest' <<<"$output"
}

@test "a scene break with a clock sets the bar's clock; a promotion and a demote move the rung" {
  cd "$FIXTURE"
  run fx "scene_break '2:19 Look, don'\''t touch' >/dev/null; echo clock=\$_LADDER_CLOCK; ladder_set act; echo level=\$_LADDER_LEVEL"
  [[ "$output" == *"clock=2:19"* && "$output" == *"level=act"* ]]
  # the scripts move the rung where the level changes
  grep -q 'ladder_set "\$level"' "$REPO_ROOT/scripts/demo-common.sh"
  grep -q 'demote\* \]\] || ladder_refresh' "$REPO_ROOT/scripts/demo-common.sh"
}

@test "an in-character scene opens with a title card: a double box exactly STAGE_COLS wide" {
  cd "$FIXTURE"
  run bash -c "NO_WAIT=true . '$REPO_ROOT/scripts/demo-common.sh'; title_card '2:15 a.m.' 'The page'"
  [ "$status" -eq 0 ]
  out="$(strip_ansi "$output")"
  [[ "$out" == *"╔"*"║ 2:15 a.m."*"║ The page"*"╚"* ]]
  while IFS= read -r line; do
    [[ -z "$line" ]] || [ "${#line}" -eq "$STAGE_COLS" ]
  done <<<"$out"
  run bash -c "NO_WAIT=true . '$REPO_ROOT/scripts/demo-common.sh'; title_card '2:15 a.m.' 'A title far too long for the card'"
  [ "$status" -ne 0 ]
  # the cold open and the close use it
  grep -q '^title_card "5:00 p.m."' "$REPO_ROOT/scripts/demo-cold-open.sh"
  grep -q '^title_card "2:15 a.m."' "$REPO_ROOT/scripts/demo-cold-open.sh"
  grep -q '^title_card ' "$REPO_ROOT/scripts/demo-close.sh"
}
