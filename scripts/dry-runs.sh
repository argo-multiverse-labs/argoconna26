#!/usr/bin/env bash
# The dry-run harness driver (Task 6.2, Δ27): N scored investigations in N/BATCH batches, each
# batch against its own freshly re-armed incident.
#
#   scripts/dry-runs.sh N BATCH                       make dry-runs N=20 BATCH=5
#   ABLATE_TIMELINE=1 scripts/dry-runs.sh N BATCH     the same with HolmesGPT's cdevents-timeline
#                                                     toolset switched off (Δ28): writes
#                                                     .dryruns/results-ablation-<ts>.json and no summary
#
# Before every batch: `make disarm IMAGE=$CHECKOUT_STABLE_TAG` (so every incident is the same
# v1.4.1 -> v1.4.2 bump the stage shows, P14), `make rearm` (its cause:, bump: and change_ref:
# lines), a wait for the abort at the new bump revision (an earlier Degraded doesn't count), and
# a wait until the live bridge has finished with that incident, so the batch doesn't compete
# with it for HolmesGPT. Then one batch: `python -m bridge.dryrun` (bridge/src/bridge/dryrun.py),
# which reads only, posts nothing and emits no events.
#
# Runs on the host, from the main checkout, under the cluster lock (P12), never in a rung-3 run
# window. Needs autonomy `suggest` on the tracked branch. HolmesGPT is reached through a
# port-forward this script starts and stops. Secrets stay in the environment (load_env): the
# GitHub App, HOLMES_API_KEY, LITELLM_MASTER_KEY (to read the model ID behind the `rca` alias)
# and the judge's key, read from Secret judge-llm. Results go to <main checkout>/.dryruns/;
# summary.json is then applied as ConfigMap dryrun-summary (make dryrun-summary-restore).
#
# Exit codes: 1 generic, 2 usage, 3 wrong context, 4 wait timed out, 5 cluster lock held,
# 6 autonomy not suggest or a test hook active; a batch's own code otherwise (3 drift,
# 4 precondition, 5 policy tool error, 6 expected answer), and then no summary is written.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$HERE/common.sh"

APP=checkout
POLL_S="${DRYRUNS_POLL_S:-2}"
ABORT_WAIT_S="${DRYRUNS_ABORT_WAIT_S:-600}"
BRIDGE_WAIT_S="${DRYRUNS_BRIDGE_WAIT_S:-300}"
PF_PID=""
ABLATED=0

usage() { echo "usage: dry-runs.sh N BATCH   (N a multiple of BATCH; ABLATE_TIMELINE=1 for the ablation)" >&2; exit 2; }

run_make() { make -C "$COMMON_ROOT" --no-print-directory "$@"; }

# dryrun_py ARGS... : the Python half (DRYRUNS_PY replaces it in the bats tests).
dryrun_py() {
  if [[ -n "${DRYRUNS_PY:-}" ]]; then
    "$DRYRUNS_PY" "$@"
  else
    (cd "$COMMON_ROOT/bridge" && uv run --quiet python -m bridge.dryrun "$@")
  fi
}

# poll DESC TIMEOUT_S CMD... : wait until CMD succeeds, checking every POLL_S; exit 4 on timeout.
poll() {
  local desc="$1" timeout="$2" deadline
  shift 2
  deadline=$((SECONDS + timeout))
  log_info "waiting for: $desc (up to ${timeout}s)"
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      log_error "timed out after ${timeout}s waiting for: $desc"
      return 4
    fi
    sleep "$POLL_S"
  done
}

machine() { sed -n "s/^$1: //p" <<<"$2" | tail -n1; } # KEY OUTPUT

# ------------------------------------------------------------------ the incident
app_json() { k -n "$NS_ARGOCD" get application "$APP" -o json; }

# aborted_at BUMP : the Application's last sync is BUMP and it is Degraded, and the Rollout aborted.
aborted_at() {
  local app ro
  app="$(app_json)" || return 1
  jq -e --arg b "$1" '.status.operationState.syncResult.revision == $b
    and .status.sync.revision == $b and .status.health.status == "Degraded"' <<<"$app" >/dev/null || return 1
  ro="$(k -n "$NS_DEMO" get rollout "$APP" -o json)" || return 1
  jq -e '.status.abort == true' <<<"$ro" >/dev/null
}

# abort_time SINCE_EPOCH : the RolloutAborted time at or after SINCE (the event, else the Rollout's
# condition); the time it was observed, with a warning, when neither is recorded (O11: events can
# be dropped by client-go's spam filter).
abort_time() {
  local since="$1" t=""
  t="$(k -n "$NS_DEMO" get events -o json \
        --field-selector "involvedObject.kind=Rollout,involvedObject.name=$APP,reason=RolloutAborted" 2>/dev/null \
      | jq -r --argjson s "$since" '[.items[] | (.lastTimestamp // .eventTime // .metadata.creationTimestamp)
          | select(. != null) | sub("\\.[0-9]+"; "") | select(fromdateiso8601 >= $s)] | sort | last // empty' \
      2>/dev/null || true)"
  if [[ -z "$t" ]]; then
    t="$(k -n "$NS_DEMO" get rollout "$APP" -o json 2>/dev/null \
        | jq -r --argjson s "$since" '[.status.conditions[]? | select(.reason == "RolloutAborted")
            | .lastTransitionTime | select(. != null) | select(fromdateiso8601 >= $s)] | last // empty' \
        2>/dev/null || true)"
  fi
  if [[ -z "$t" ]]; then
    t="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    log_warn "no RolloutAborted time recorded; using the time the abort was seen ($t)"
  fi
  printf '%s' "$t"
}

bridge_status() { curl -sf --max-time 5 "http://${HOST_BIND}:${PORT_BRIDGE}/status"; }

# bridge_done BUMP : the live bridge has finished with the incident for BUMP and has nothing queued.
bridge_done() {
  bridge_status | jq -e --arg k "$APP@$1" \
    '.last_incident.key == $k and .last_incident.state != "running" and .queue_depth == 0' >/dev/null
}

# ------------------------------------------------------------------ what the summary states
litellm_model_id() { # the provider model behind the rca alias (D17), from LiteLLM's /model/info
  [[ -n "${LITELLM_MASTER_KEY:-}" ]] || return 1
  curl -sf --max-time 10 -K <(printf 'header = "Authorization: Bearer %s"\n' "$LITELLM_MASTER_KEY") \
    "${LITELLM_HOST_URL}/model/info" \
    | jq -r --arg a "$LLM_ALIAS_RCA" '[.data[]? | select(.model_name == $a) | .litellm_params.model]
        | if length == 1 then .[0] else empty end'
}

model_temperature() { # what Holmes sends for the rca model (O10)
  yq -r '.modelList.rca.temperature // ""' "$COMMON_ROOT/platform/holmes/values.yaml"
}

judge_key() {
  k -n "$NS_AIOPS" get secret judge-llm -o jsonpath='{.data.OPENAI_API_KEY}' | base64 -d
}

# ------------------------------------------------------------------ HolmesGPT
free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

holmes_ready() { kill -0 "$PF_PID" 2>/dev/null && curl -sf --max-time 3 "http://127.0.0.1:$PF_PORT/readyz"; }

start_port_forward() {
  [[ "${KUBECONFIG:-}" == "$(_isolated_kubeconfig)" ]] || die "refusing kubectl: not the isolated kubeconfig"
  PF_PORT="$(free_port)"
  kubectl --context "$CLUSTER_CONTEXT" -n "$NS_AIOPS" port-forward "svc/${HOLMES_RELEASE}-holmes" \
    "127.0.0.1:${PF_PORT}:80" >"$RUN_DIR/port-forward.log" 2>&1 &
  PF_PID=$!
  poll "HolmesGPT on 127.0.0.1:$PF_PORT" 60 holmes_ready
}

stop_port_forward() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
    PF_PID=""
  fi
}

# The release's values say whether the timeline toolset is on (true/false).
timeline_toolset() {
  h get values "$HOLMES_RELEASE" -n "$NS_AIOPS" -o json | jq -r '.toolsets["cdevents-timeline"].enabled'
}

ablate_on() {
  log_info "ablation: re-installing HolmesGPT with the cdevents-timeline toolset off"
  ABLATED=1
  run_make holmes-install HOLMES_SET=toolsets.cdevents-timeline.enabled=false
  [[ "$(timeline_toolset)" == false ]] || die "ablation: the timeline toolset is still enabled"
}

ablate_off() {
  log_info "ablation: re-installing HolmesGPT with the committed values"
  run_make holmes-install || { log_error "ablation: restoring HolmesGPT failed; run make holmes-install"; return 1; }
  if [[ "$(timeline_toolset)" != true ]]; then
    log_error "ablation: the timeline toolset is not enabled again; run make holmes-install"
    return 1
  fi
  ABLATED=0
  log_info "ablation: the timeline toolset is enabled again"
}

on_exit() {
  local rc=$?
  stop_port_forward
  if ((ABLATED)); then ablate_off || rc=1; fi
  exit "$rc"
}

# ------------------------------------------------------------------ the scratch clone
# Where the expected answer is read from and policy_ok's temporary commits are made. Never pushed.
scratch_sync() {
  local remote="${DRYRUNS_REMOTE:-https://github.com/${REPO_SLUG}.git}"
  if [[ ! -d "$SCRATCH/.git" ]]; then
    mkdir -p "$(dirname "$SCRATCH")"
    git clone --quiet --no-checkout "$remote" "$SCRATCH"
  fi
  git -C "$SCRATCH" fetch --quiet origin "+refs/heads/${TRACKED_BRANCH}:refs/remotes/origin/${TRACKED_BRANCH}"
}

# ------------------------------------------------------------------ main
main() {
  (($# == 2)) || usage
  local n="$1" per="$2" batches b ts out cause bump ref since abort threshold status model_id temp rc
  [[ "$n" =~ ^[1-9][0-9]*$ && "$per" =~ ^[1-9][0-9]*$ ]] || usage
  ((n % per == 0)) || usage
  batches=$((n / per))
  load_env
  require_context
  cluster_lock
  [[ "$COMMON_ROOT" -ef "$(main_root)" || "${DRYRUNS_ANY_CHECKOUT:-0}" == 1 ]] \
    || die "run dry-runs from the main checkout ($(main_root)), not a worktree (P12)"

  local level
  level="$(tracked_autonomy_level)" || die "cannot read $AUTONOMY_FILE on $TRACKED_BRANCH"
  [[ "$level" == suggest ]] || refuse 6 "autonomy is $level" "dry-runs: autonomy on $TRACKED_BRANCH is $level; lower it to suggest first (make demote)"

  status="$(bridge_status)" || die "the bridge's /status is not reachable on ${HOST_BIND}:${PORT_BRIDGE}"
  jq -e '.test_hooks_active == false' <<<"$status" >/dev/null \
    || refuse 6 "test hook active" "dry-runs: a bridge test hook is active (make bridge-hooks-clear)"
  threshold="$(jq -r '.confidence_threshold' <<<"$status")"
  [[ "$threshold" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "the bridge reports no confidence threshold"
  temp="$(model_temperature)"
  [[ "$temp" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "no modelList.rca.temperature in platform/holmes/values.yaml"
  model_id="$(litellm_model_id)" || true
  [[ -n "$model_id" ]] || die "cannot read the model behind '$LLM_ALIAS_RCA' from LiteLLM /model/info (LITELLM_MASTER_KEY?)"
  JUDGE_API_KEY="$(judge_key)" || true
  [[ -n "$JUDGE_API_KEY" ]] || die "Secret judge-llm has no key (make litellm-keys)"
  export JUDGE_API_KEY
  [[ -n "${HOLMES_API_KEY:-}" ]] || die "HOLMES_API_KEY is missing in .env"

  DRYRUNS_DIR="$(main_root)/.dryruns"
  SCRATCH="$DRYRUNS_DIR/scratch/repo"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_DIR="$DRYRUNS_DIR/run-$ts"
  mkdir -p "$RUN_DIR"
  log_info "dry-runs: $n runs in $batches batches of $per (threshold $threshold, model $model_id, temperature $temp)"
  log_info "dry-runs: results in $RUN_DIR"

  trap on_exit EXIT
  if [[ "${ABLATE_TIMELINE:-0}" == 1 ]]; then ablate_on; fi
  start_port_forward

  for ((b = 1; b <= batches; b++)); do
    log_info "dry-runs: batch $b of $batches: disarm, then rearm"
    run_make disarm IMAGE="$CHECKOUT_STABLE_TAG"
    since="$(date +%s)"
    out="$(STAGE=0 run_make rearm)"
    cause="$(machine cause "$out")" bump="$(machine bump "$out")" ref="$(machine change_ref "$out")"
    [[ "$cause" =~ ^[0-9a-f]{40}$ && "$bump" =~ ^[0-9a-f]{40}$ && "$ref" =~ ^CHG-[A-Z2-7]{6}$ ]] \
      || die "rearm did not print cause:, bump: and change_ref:"
    poll "the abort at ${bump:0:7}" "$ABORT_WAIT_S" aborted_at "$bump"
    abort="$(abort_time "$since")"
    poll "the live bridge to finish $APP@${bump:0:7}" "$BRIDGE_WAIT_S" bridge_done "$bump"
    scratch_sync
    rc=0
    dryrun_py --n "$per" --app "$APP" --expected-from-git --batch-id "$b" \
      --holmes-url "http://127.0.0.1:$PF_PORT" --repo "$SCRATCH" --tracked-ref "origin/$TRACKED_BRANCH" \
      --bump "$bump" --change-ref "$ref" --abort-at "$abort" --threshold "$threshold" --out-dir "$RUN_DIR" \
      --sim-url "$(_sim_url)" --litellm-url "${LITELLM_HOST_URL}/v1" --policy-dir "$COMMON_ROOT/policy" \
      --conftest-version "$CONFTEST_VERSION" --kube-context "$CLUSTER_CONTEXT" || rc=$?
    if ((rc != 0)); then
      log_error "dry-runs: batch $b stopped (exit $rc); no summary is written"
      exit "$rc"
    fi
  done
  stop_port_forward

  if ((ABLATED)); then
    dryrun_py --summarize "$RUN_DIR" --batches "$batches" --ablation \
      --results-out "$DRYRUNS_DIR/results-ablation-$ts.json"
    return 0
  fi
  dryrun_py --summarize "$RUN_DIR" --batches "$batches" --results-out "$DRYRUNS_DIR/results-$ts.json" \
    --summary-out "$DRYRUNS_DIR/summary.json" --model-temperature "$temp" --model-id "$model_id"
  run_make dryrun-summary-restore
}

main "$@"
