#!/usr/bin/env bats
# Tests for scripts/night.sh, the rendered units and preflight's job section.
# systemctl, gh, kubectl and the armed preflight are stubs; nothing touches systemd or GitHub.

load helpers

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$FIXTURE"
  mkdir -p "$FIXTURE/.kube"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run" SYSTEMD_USER_DIR="$BATS_TEST_TMPDIR/units"
  mkdir -p "$XDG_RUNTIME_DIR"
  LOG="$BATS_TEST_TMPDIR/calls.log"
  : >"$LOG"
  export LOG
  STUBS="$BATS_TEST_TMPDIR/stubs"
  make_stub "$STUBS" systemctl 'echo "systemctl $*" >>"$LOG"
    case "$*" in *" show "*) echo "${UNIT_STATUS:-0}" ;; esac'
  make_stub "$STUBS" gh 'case "$*" in
    "auth token") echo tok123 ;;
    *contents/aiops/autonomy.yaml*) printf "level: %s\npromotion:\n  approved_by: admin-bypass\n" "${AUTONOMY:-act}" ;;
    "pr list"*) echo "[{\"number\":7,\"headRefName\":\"promote/act-20261102000000-ab12\"}]" ;;
    *contents/.github/CODEOWNERS*) echo CODEOWNERS ;;
    *rules/branches/*) if [[ -n "${RULES_JSON:-}" ]]; then printf "%s\n" "$RULES_JSON"; else echo "[{\"type\":\"pull_request\",\"parameters\":{\"require_code_owner_review\":true}},{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"policy-check\",\"integration_id\":15368}]}}]"; fi ;;
    "api user"*)
      echo "gh GH_TOKEN=${GH_TOKEN:-}" >>"$LOG"
      if [[ -n "${GH_CHECK:-}" && "GH_TOKEN=${GH_TOKEN:-}" != "$(cat "$GH_CHECK")" ]]; then exit 1; fi
      echo login ;;
  esac'
  make_stub "$STUBS" kubectl 'echo kind-argoconna26'
  make_stub "$STUBS" preflight 'echo "preflight $*" >>"$LOG"; exit "${PREFLIGHT_RC:-0}"'
  # jq is the real one: preflight reads the rules JSON with it.
  for t in kind docker; do make_stub "$STUBS" "$t" 'exit 0'; done
  # uv: only preflight's App check (bridge.cli app-check) calls it here; a clean installation.
  make_stub "$STUBS" uv 'echo "{\"token_minted\":true,\"permissions\":{\"contents\":\"write\",\"pull_requests\":\"write\"}}"'
  export PATH="$STUBS:$PATH" TOOLS_BIN="$STUBS" NIGHT_PREFLIGHT="$STUBS/preflight"
  export STAGE_STRICT=1
}

night() { (cd "$FIXTURE" && "$REPO_ROOT/scripts/night.sh" "$@"); }

started() { grep -c -- '--user start argoconna26-rearm.service' "$LOG" || true; }

@test "night refuses when autonomy not act" {
  AUTONOMY=propose run night night
  [ "$status" -eq 6 ]
  [[ "$output" == *"not act"* ]]
  [ "$(started)" -eq 0 ]
}

@test "night refuses under a held cluster_lock" {
  ( exec 9>>"$FIXTURE/.kube/cluster.lock"; flock -n 9; sleep 20 ) &
  holder=$!
  wait_file "$FIXTURE/.kube/cluster.lock"
  sleep 0.5
  echo "4242 make rearm" >"$FIXTURE/.kube/cluster.lock"
  CLUSTER_LOCK_HELD=4242 run night night
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 5 ]
  [[ "$output" == *"4242 make rearm"* ]]
  [ "$(started)" -eq 0 ]
  [ ! -e "$XDG_RUNTIME_DIR/argoconna26/job.env" ]
}

@test "night refuses when preflight 3 --armed fails" {
  PREFLIGHT_RC=1 run night night
  [ "$status" -eq 9 ]
  grep -q '^preflight 3 --armed$' "$LOG"
  [ "$(started)" -eq 0 ]
}

@test "night starts the same unit the timer starts" {
  run night job-install
  [ "$status" -eq 0 ]
  run night night
  [ "$status" -eq 0 ]
  [ "$(started)" -eq 1 ]
  at="$(date -d '+1 day' '+%Y-%m-%d %H:%M')"
  run night timer-arm "$at"
  [ "$status" -eq 0 ]
  grep -qx 'Unit=argoconna26-rearm.service' "$SYSTEMD_USER_DIR/argoconna26-rearm.timer"
  [ -f "$SYSTEMD_USER_DIR/argoconna26-rearm.service" ]
  grep -q -- '--user start argoconna26-rearm.timer' "$LOG"
}

@test "night writes job.env 0600 outside the repo and the unit removes it in ExecStopPost" {
  night job-install
  run night night
  [ "$status" -eq 0 ]
  f="$XDG_RUNTIME_DIR/argoconna26/job.env"
  [ "$(stat -c %a "$f")" = 600 ]
  [ "$(cat "$f")" = "GH_TOKEN=tok123" ]
  [[ "$f" != "$FIXTURE"/* ]]
  grep -qx 'ExecStopPost=/usr/bin/rm -f %t/argoconna26/job.env' "$SYSTEMD_USER_DIR/argoconna26-rearm.service"
  grep -qx 'EnvironmentFile=-%t/argoconna26/job.env' "$SYSTEMD_USER_DIR/argoconna26-rearm.service"
  [[ "$output" != *tok123* ]]
}

@test "night exits with the unit's ExecMainStatus" {
  UNIT_STATUS=3 run night night
  [ "$status" -eq 3 ]
}

@test "night under STAGE=1 prints one line within STAGE_COLS" {
  STAGE=1 run night night
  [ "$status" -eq 0 ]
  [ "$output" = "running the nightly job now" ]
  [ "${#output}" -le 30 ]
  [[ "$output" != *03:00* ]]
}

@test "night records RUN_TS and RUN_MONO under .operator" {
  run night night
  [ "$status" -eq 0 ]
  grep -qE '^RUN_TS=[0-9]+$' "$FIXTURE/.operator/last-run"
  grep -qE '^RUN_MONO=[0-9]+$' "$FIXTURE/.operator/last-run"
}

@test "night records T_TYPED, taken before its own preflight, no later than RUN_TS" {
  make_stub "$STUBS" preflight 'echo "preflight $*" >>"$LOG"; sleep 1.2; exit 0'
  run night night
  [ "$status" -eq 0 ]
  typed="$(sed -n 's/^T_TYPED=//p' "$FIXTURE/.operator/last-run")"
  run_ts="$(sed -n 's/^RUN_TS=//p' "$FIXTURE/.operator/last-run")"
  [[ "$typed" =~ ^[0-9]+$ ]]
  [ "$typed" -lt "$run_ts" ]
}

@test "timer-arm refuses past time" {
  run night timer-arm "2020-01-01 03:00"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not in the future"* ]]
  [ "$(started)" -eq 0 ]
  ! grep -q 'timer' "$LOG"
}

@test "timer-arm refuses a malformed time" {
  run night timer-arm "tomorrow"
  [ "$status" -eq 2 ]
}

@test "rendered timer has OnCalendar and Persistent=false" {
  night job-install
  at="$(date -d '+1 day' '+%Y-%m-%d %H:%M')"
  night timer-arm "$at"
  grep -qx "OnCalendar=$at" "$SYSTEMD_USER_DIR/argoconna26-rearm.timer"
  grep -qx 'Persistent=false' "$SYSTEMD_USER_DIR/argoconna26-rearm.timer"
  grep -qx 'AccuracySec=1s' "$SYSTEMD_USER_DIR/argoconna26-rearm.timer"
}

@test "timer-disarm removes the timer and job.env" {
  night job-install
  night timer-arm "$(date -d '+1 day' '+%Y-%m-%d %H:%M')"
  [ -f "$XDG_RUNTIME_DIR/argoconna26/job.env" ]
  run night timer-disarm
  [ "$status" -eq 0 ]
  [ ! -e "$SYSTEMD_USER_DIR/argoconna26-rearm.timer" ]
  [ ! -e "$XDG_RUNTIME_DIR/argoconna26/job.env" ]
}

@test "rendered service runs the quiet rung-3 preflight before rearm, without make" {
  night job-install
  line="$(grep '^ExecStart=' "$SYSTEMD_USER_DIR/argoconna26-rearm.service")"
  [[ "$line" == *"$FIXTURE/scripts/preflight.sh\" 3 --armed --job-run --quiet && \"$FIXTURE/scripts/rearm.sh\""* ]]
  [[ "$line" != *"make "* ]]
  [[ "$line" == *"rung3-run-"* ]]
  grep -qx "Environment=KUBECONFIG=$FIXTURE/.kube/argoconna26.yaml" "$SYSTEMD_USER_DIR/argoconna26-rearm.service"
  ! grep -q '@[A-Z_]*@' "$SYSTEMD_USER_DIR/argoconna26-rearm.service"
}

# The rendered ExecStart as bash would run it: systemd's $$ and %% escapes undone.
exec_start() { sed -n 's/^ExecStart=\/usr\/bin\/env bash -o pipefail -c //p' "$SYSTEMD_USER_DIR/argoconna26-rearm.service" \
  | sed -e "s/^'//" -e "s/'\$//" -e 's/\$\$/$/g' -e 's/%%/%/g'; }

@test "rendered service passes rearm's own exit status through (no make, no 2)" {
  night job-install
  mkdir -p "$FIXTURE/scripts" "$BATS_TEST_TMPDIR/ev"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$FIXTURE/scripts/preflight.sh"
  printf '#!/usr/bin/env bash\necho "rearm: armed already"; exit 7\n' >"$FIXTURE/scripts/rearm.sh"
  chmod +x "$FIXTURE/scripts/preflight.sh" "$FIXTURE/scripts/rearm.sh"
  run bash -o pipefail -c "$(exec_start)"
  [ "$status" -eq 7 ]
  printf '#!/usr/bin/env bash\nexit 1\n' >"$FIXTURE/scripts/preflight.sh"
  run bash -o pipefail -c "$(exec_start)"
  [ "$status" -eq 1 ]
}

@test "rendered service PATH resolves the pinned tools" {
  decoy="$BATS_TEST_TMPDIR/decoy"
  make_stub "$decoy" kubectl 'echo decoy'
  PATH="$PATH:$decoy" night job-install
  p="$(sed -n 's/^Environment="PATH=\(.*\)"$/\1/p' "$SYSTEMD_USER_DIR/argoconna26-rearm.service")"
  [ -n "$p" ]
  [[ "$p" == "$STUBS":* ]]
  run env -i PATH="$p" "$(command -v bash)" -c 'command -v kind kubectl yq uv docker'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$STUBS/kind"* && "$output" == *"$STUBS/kubectl"* ]]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 5 ]
}

# ---------------------------------------------------------------- preflight job section
# Runs preflight's main with every section but github_runtime replaced by a no-op (github_admin
# by a marker). The App check is hard by default (PREFLIGHT_L5B=1); the uv stub answers it.
run_job_preflight() {
  bash -c "cd '$FIXTURE' && . '$REPO_ROOT/scripts/preflight.sh'
    keep=\$(declare -f section_github_runtime)
    for s in \$(compgen -A function section_ | sed s/section_//); do eval \"section_\$s() { :; }\"; done
    eval \"\$keep\"
    section_github_admin() { echo ADMIN-RAN; }
    main $*"
}

@test "preflight-rung3-quiet runs no github-admin check and every gh call carries GH_TOKEN from job.env" {
  night job-install
  night night
  GH_CHECK="$XDG_RUNTIME_DIR/argoconna26/job.env" GH_TOKEN=tok123 AUTONOMY=act run run_job_preflight 3 --armed --job-run --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qx 'gh GH_TOKEN=tok123' "$LOG"
}

@test "preflight --job-run fails without GH_TOKEN, and with a token that is not job.env's" {
  night night
  GH_CHECK="$XDG_RUNTIME_DIR/argoconna26/job.env" run run_job_preflight 3 --armed --job-run --quiet
  [ "$status" -eq 1 ]
  [[ "$output" == *"GH_TOKEN is not set"* ]]
  GH_CHECK="$XDG_RUNTIME_DIR/argoconna26/job.env" GH_TOKEN=other run run_job_preflight 3 --armed --job-run --quiet
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh api user failed"* ]]
}

@test "preflight without --job-run still runs github-admin" {
  GH_TOKEN= run run_job_preflight 3 --armed
  [[ "$output" == *"ADMIN-RAN"* ]]
}

@test "preflight 3 --armed fails unless autonomy is act, --pre-promotion unless it is propose" {
  AUTONOMY=propose run run_job_preflight 3 --armed --quiet
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected act"* ]]
  AUTONOMY=propose run run_job_preflight 3 --pre-promotion --quiet
  [ "$status" -eq 0 ]
}

@test "preflight 3 --armed fails unless the tracked branch requires policy-check (read-only rules)" {
  RULES_JSON='[{"type":"pull_request","parameters":{}}]' AUTONOMY=act run run_job_preflight 3 --armed --quiet
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not require policy-check"* ]]
  RULES_JSON='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"policy-check","integration_id":1}]}}]' \
    AUTONOMY=act run run_job_preflight 3 --armed --quiet
  [ "$status" -eq 1 ]
  AUTONOMY=act run run_job_preflight 3 --armed --quiet
  [ "$status" -eq 0 ]
  AUTONOMY=propose RULES_JSON='[]' run run_job_preflight 3 --pre-promotion --quiet
  [ "$status" -eq 0 ]
}
