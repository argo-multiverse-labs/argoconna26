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
  [scene-2]="intro promotion board incident-again identity fix-pr review merged rejected act-offstage"
  [scene-3]="intro board policy teach pr policy-pass merged healthy verify"
  [epilogue]="panel verifier real simulated valve safe"
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

# placeholders_ok DIR : in DIR/*.txt every line that opens a bracket is exactly an SRE placeholder.
placeholders_ok() {
  local f line bad=0 re='^# \[SRE: [^]]+\]$'
  for f in "$1"/*.txt; do
    [[ -e "$f" ]] || continue
    while IFS= read -r line; do
      [[ "$line" =~ $re ]] || { printf '%s: %s\n' "$f" "$line" >&2; bad=1; }
    done < <(grep -E '\[' "$f" | grep -v '^\[[a-z0-9-]*\]$' || true)
  done
  return "$bad"
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
  ! grep -v '^#' "$REPO_ROOT/scripts/demo-full.sh" | grep -q 'reset'
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
  [[ "$(strip_ansi "$output")" == *"> Platform Engineer"*"> On-call SRE"* ]]
  run bash -c "NO_WAIT=true . '$REPO_ROOT/scripts/demo-common.sh'; speaker_beat luke t"
  [ "$status" -ne 0 ]
  # every cue in the scripts is one of the three
  ! grep -hoE '^[[:space:]]*speaker_beat [a-z]+' "$REPO_ROOT"/scripts/demo-*.sh | grep -vE 'speaker_beat (pe|sre|both)$'
}

@test "SRE lines are placeholders only, and no speaker is named" {
  placeholders_ok "$NARRATION_DIR"
  placeholders_ok "$REPO_ROOT/tests/bats/fixtures/scene-text"
  # the real narration, when it exists (local only, in the main checkout)
  main="$(dirname "$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)")"
  placeholders_ok "$main/narration"
  # and the check itself catches wording
  mkdir -p "$BATS_TEST_TMPDIR/bad"
  printf '[k]\n# [SRE: topic] and some words\n' >"$BATS_TEST_TMPDIR/bad/x.txt"
  run placeholders_ok "$BATS_TEST_TMPDIR/bad"
  [ "$status" -ne 0 ]
  printf '[k]\n# [Someone: topic]\n' >"$BATS_TEST_TMPDIR/bad/x.txt"
  run placeholders_ok "$BATS_TEST_TMPDIR/bad"
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
