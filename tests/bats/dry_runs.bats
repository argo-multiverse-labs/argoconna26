#!/usr/bin/env bats
# Tests for scripts/dry-runs.sh (Task 6.2). make, kubectl, helm, curl and gh are stubs, and the
# Python half is replaced by DRYRUNS_PY. git, jq and yq are real. Nothing touches a cluster or GitHub.

load helpers

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$FIXTURE"
  git -C "$FIXTURE" branch build/demo
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git clone -q --bare "$FIXTURE" "$REMOTE"
  mkdir -p "$FIXTURE/.kube"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE"
  printf 'a%.0s' {1..40} >"$STATE/old"
  cp "$STATE/old" "$STATE/bump"
  echo true >"$STATE/toolset"
  LOG="$BATS_TEST_TMPDIR/calls.log"
  : >"$LOG"
  export STATE LOG

  STUBS="$BATS_TEST_TMPDIR/stubs"
  make_stub "$STUBS" make 'echo "make $*" >>"$LOG"
    case "$*" in
      *" rearm"*)
        n=$(( $(cat "$STATE/n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$STATE/n"
        cp "$STATE/bump" "$STATE/old"
        printf "b%039d" "$n" >"$STATE/bump"
        echo "${STALE:-0}" >"$STATE/stale"
        echo "pushed: config 200"
        printf "cause: c%039d\nbump: %s\nchange_ref: CHG-ABCDE%s\n" "$n" "$(cat "$STATE/bump")" "$((n + 1))" ;;
      *"holmes-install HOLMES_SET=toolsets.cdevents-timeline.enabled=false"*) echo false >"$STATE/toolset" ;;
      *holmes-install*) echo true >"$STATE/toolset" ;;
    esac'
  make_stub "$STUBS" kubectl 'echo "kubectl $*" >>"$LOG"
    case "$*" in
      *"config current-context"*) echo kind-argoconna26 ;;
      *"get application"*)
        stale=$(cat "$STATE/stale" 2>/dev/null || echo 0)
        if [ "$stale" -gt 0 ]; then echo $((stale - 1)) >"$STATE/stale"; rev=$(cat "$STATE/old"); else rev=$(cat "$STATE/bump"); fi
        jq -n --arg r "$rev" "{status: {health: {status: \"Degraded\"}, sync: {revision: \$r}, operationState: {syncResult: {revision: \$r}}}}" ;;
      *"get rollout"*) echo "{\"status\": {\"abort\": true}}" ;;
      *"get events"*) jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "{items: [{lastTimestamp: \$t}]}" ;;
      *"get secret judge-llm"*) printf judge-key-not-a-secret | base64 ;;
      *port-forward*) echo $$ >"$STATE/pf.pid"; exec sleep 30 ;;
    esac'
  make_stub "$STUBS" helm 'echo "helm $*" >>"$LOG"
    case "$*" in *"get values"*) printf "{\"toolsets\": {\"cdevents-timeline\": {\"enabled\": %s}}}\n" "$(cat "$STATE/toolset")" ;; esac'
  make_stub "$STUBS" curl 'echo "curl $*" >>"$LOG"
    case "$*" in
      */status*) jq -n --arg k "checkout@$(cat "$STATE/bump")" --argjson hooks "${HOOKS:-false}" \
          "{test_hooks_active: \$hooks, confidence_threshold: 0.7, queue_depth: 0, last_incident: {key: \$k, state: \"done\"}}" ;;
      */model/info*) echo "{\"data\": [{\"model_name\": \"rca\", \"litellm_params\": {\"model\": \"anthropic/claude-sonnet-5-5\"}}]}" ;;
      */readyz*) echo ok ;;
      *) exit 7 ;;
    esac'
  make_stub "$STUBS" gh 'case "$*" in *contents/aiops/autonomy.yaml*) printf "level: %s\n" "${AUTONOMY:-suggest}" ;; *) exit 1 ;; esac'
  make_stub "$STUBS" dryrun 'echo "dryrun $*" >>"$LOG"
    if [[ " $* " == *" --summarize "* ]]; then
      args=("$@")
      for ((i = 0; i < ${#args[@]}; i++)); do
        [[ "${args[i]}" == --summary-out ]] && echo "{\"n\": 4, \"root_cause_matched\": 4}" >"${args[i+1]}"
        [[ "${args[i]}" == --results-out ]] && echo "{}" >"${args[i+1]}"
      done
      exit 0
    fi
    exit "${DRYRUN_RC:-0}"'

  export PATH="$STUBS:$PATH" TOOLS_BIN="$STUBS" DRYRUNS_PY="$STUBS/dryrun" DRYRUNS_REMOTE="$REMOTE"
  export DRYRUNS_ANY_CHECKOUT=1 DRYRUNS_POLL_S=0.05 LITELLM_MASTER_KEY=master-not-a-secret
  export HOLMES_API_KEY=holmes-not-a-secret
}

teardown() {
  if [[ -s "$STATE/pf.pid" ]]; then kill "$(cat "$STATE/pf.pid")" 2>/dev/null || true; fi
}

dry_runs() { (cd "$FIXTURE" && "$REPO_ROOT/scripts/dry-runs.sh" "$@"); }

# The make, dryrun and holmes lines of the call log, in order.
steps() { grep -E '^(make|dryrun) ' "$LOG" | sed -E 's/ -C [^ ]+ --no-print-directory//'; }

@test "dry-runs disarms then rearms before every batch" {
  run dry_runs 4 2
  [ "$status" -eq 0 ]
  mapfile -t s < <(steps)
  [ "${s[0]}" = "make disarm IMAGE=v1.4.1" ]
  [ "${s[1]}" = "make rearm" ]
  [[ "${s[2]}" == "dryrun --n 2 --app checkout --expected-from-git --batch-id 1 "* ]]
  [ "${s[3]}" = "make disarm IMAGE=v1.4.1" ]
  [ "${s[4]}" = "make rearm" ]
  [[ "${s[5]}" == "dryrun --n 2 --app checkout --expected-from-git --batch-id 2 "* ]]
  [[ "${s[6]}" == "dryrun --summarize "*" --batches 2 "* ]]
  [ "${s[7]}" = "make dryrun-summary-restore" ]
  [ "${#s[@]}" -eq 8 ]
  # each batch runs against its own rearm's incident
  [[ "${s[2]}" == *"--bump b$(printf '%039d' 1) --change-ref CHG-ABCDE2 "* ]]
  [[ "${s[5]}" == *"--bump b$(printf '%039d' 2) --change-ref CHG-ABCDE3 "* ]]
  [[ "${s[2]}" == *"--threshold 0.7 "* && "${s[2]}" == *"--holmes-url http://127.0.0.1:"* ]]
  [[ "${s[2]}" == *"--tracked-ref origin/build/demo "* && "${s[2]}" == *"--policy-dir $REPO_ROOT/policy "* ]]
  [[ "${s[6]}" == *"--model-temperature 1 --model-id anthropic/claude-sonnet-5-5"* ]]
  [[ "${s[6]}" == *"--summary-out $FIXTURE/.dryruns/summary.json"* ]]
  [ -s "$FIXTURE/.dryruns/summary.json" ]
  # the scratch clone exists and has the tracked branch
  git -C "$FIXTURE/.dryruns/scratch/repo" rev-parse --verify -q origin/build/demo >/dev/null
  # no secret on any command line
  ! grep -qE 'judge-key-not-a-secret|master-not-a-secret|holmes-not-a-secret' "$LOG"
  # the port-forward this script started is gone
  ! kill -0 "$(cat "$STATE/pf.pid")" 2>/dev/null
}

@test "dry-runs waits for abort at the new bump revision" {
  # After the rearm the Application stays Degraded at the old revision for three reads.
  STALE=3 run dry_runs 1 1
  [ "$status" -eq 0 ]
  log="$(cat "$LOG")"
  between="$(sed -n '/^make .* rearm$/,/^dryrun --n/p' <<<"$log")"
  [ "$(grep -c 'get application checkout' <<<"$between")" -ge 4 ]
  grep -q "^dryrun --n 1 .*--bump b$(printf '%039d' 1) " "$LOG"
}

@test "dry-runs never runs a batch while the Application is Degraded at an older revision" {
  STALE=100000 DRYRUNS_ABORT_WAIT_S=1 run dry_runs 1 1
  [ "$status" -eq 4 ]
  [[ "$output" == *"timed out"*"abort at bbbbbbb"* || "$output" == *"timed out"*"abort at b000000"* ]]
  ! grep -q '^dryrun ' "$LOG"
}

@test "dry-runs refuses unless autonomy is suggest, before touching anything" {
  AUTONOMY=act run dry_runs 2 1
  [ "$status" -eq 6 ]
  [[ "$output" == *"suggest"* ]]
  ! grep -qE '^(make|dryrun) ' "$LOG"
}

@test "dry-runs refuses while a bridge test hook is active" {
  HOOKS=true run dry_runs 2 1
  [ "$status" -eq 6 ]
  ! grep -qE '^(make|dryrun) ' "$LOG"
}

@test "a failed batch (drift) stops the run and writes no summary" {
  DRYRUN_RC=3 run dry_runs 4 2
  [ "$status" -eq 3 ]
  [ "$(grep -c '^dryrun --n' "$LOG")" -eq 1 ]
  ! grep -q -- '--summarize' "$LOG"
  ! grep -q 'dryrun-summary-restore' "$LOG"
  [ ! -e "$FIXTURE/.dryruns/summary.json" ]
}

@test "dry-runs checks its arguments" {
  run dry_runs 5 2
  [ "$status" -eq 2 ]
  run dry_runs 0 1
  [ "$status" -eq 2 ]
  run dry_runs 4
  [ "$status" -eq 2 ]
  ! grep -qE '^(make|dryrun) ' "$LOG"
}

@test "ABLATE_TIMELINE=1 turns the timeline toolset off, writes no summary and turns it back on" {
  ABLATE_TIMELINE=1 run dry_runs 2 2
  [ "$status" -eq 0 ]
  mapfile -t s < <(steps)
  [ "${s[0]}" = "make holmes-install HOLMES_SET=toolsets.cdevents-timeline.enabled=false" ]
  [[ "${s[3]}" == "dryrun --n 2 "* ]]
  [[ "${s[4]}" == "dryrun --summarize "*" --ablation --results-out $FIXTURE/.dryruns/results-ablation-"*.json ]]
  [ "${s[5]}" = "make holmes-install" ]
  [ "${#s[@]}" -eq 6 ]
  ! grep -q -- '--summary-out' "$LOG"
  ! grep -q 'dryrun-summary-restore' "$LOG"
  [ ! -e "$FIXTURE/.dryruns/summary.json" ]
  [ "$(cat "$STATE/toolset")" = true ]
  # the port-forward starts after the re-install (the HolmesGPT pod restarts)
  pf="$(grep -n 'port-forward' "$LOG" | head -1 | cut -d: -f1)"
  ablate="$(grep -n 'HOLMES_SET' "$LOG" | head -1 | cut -d: -f1)"
  [ "$ablate" -lt "$pf" ]
}

@test "the ablation restores HolmesGPT even when a batch fails" {
  ABLATE_TIMELINE=1 DRYRUN_RC=5 run dry_runs 2 2
  [ "$status" -eq 5 ]
  [ "$(steps | tail -1)" = "make holmes-install" ]
  [ "$(cat "$STATE/toolset")" = true ]
}
