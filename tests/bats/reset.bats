#!/usr/bin/env bats
# Tests for scripts/reset.sh and the reset-* make targets. GitHub is a local bare repo, gh,
# kubectl and curl are stubs (see ops_helpers.bash and promotion_helpers.bash), the operator
# clone is real. Nothing touches a cluster or the network.

bats_require_minimum_version 1.5.0
load helpers
load ops_helpers
load promotion_helpers

CFG=apps/checkout/config/checkout-config.yaml
ROLL=apps/checkout/deploy/rollout.yaml
KUST=apps/checkout/kustomization.yaml
RESET="$REPO_ROOT/scripts/reset.sh"

make_reset_fixture() {
  make_promotion_fixture
  AGENT_STATE="$BATS_TEST_TMPDIR/agent-prs"
  mkdir -p "$AGENT_STATE"
  echo 100 > "$PROMO_STATE/next" # promotion PRs are numbered 101 and up
  export AGENT_STATE
  _reset_stubs
}

# The reset adds calls the base stubs don't know. Each wrapper handles those and hands the rest
# to the original, kept as <name>.base.
_reset_stubs() {
  local n
  for n in kubectl curl gh; do mv "$STUBS/$n" "$STUBS/$n.base"; done
  cat > "$STUBS/kubectl" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"annotate application checkout"*"notified.notifications.argoproj.io-"*) echo NOTIFIED_CLEAR >> "$CALLS" ;;
  *"get secret bridge-env"*)
    [ -e "$STUBS/BRIDGE_ENV" ] && echo '{"data":{"TEST_HOLMES_TIMEOUT_S":"MQ=="}}' ;;
  *"delete secret bridge-env"*) rm -f "$STUBS/BRIDGE_ENV"; echo HOOKS_CLEARED >> "$CALLS" ;;
  *"delete pod"*) echo BRIDGE_POD_DELETE >> "$CALLS" ;;
  *"rollout status"*) ;;
  *) exec "$STUBS/kubectl.base" "\$@" ;;
esac
STUB
  cat > "$STUBS/curl" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *127.0.0.1:30081/status*) echo '{"test_hooks_active": false}' ;;
  *127.0.0.1:30082/seed*)
    echo "\$*" | grep -o '/seed[^ ]*' >> "$STUBS/seed-urls.log"
    exec "$STUBS/curl.base" "\$@" ;;
  *checkout_config_upstream_timeout_ms*)
    # STALE_PODS: the pods read 200 until a "roll checkout pods" commit is on the tracked branch.
    if [ -e "$STUBS/STALE_PODS" ]; then
      if "$REAL_GIT" --git-dir="$ORIGIN" log --format=%s refs/heads/build/demo | grep -q 'roll checkout pods'; then
        rm -f "$STUBS/FORCE_GAUGE"; else echo 200 > "$STUBS/FORCE_GAUGE"; fi
    fi
    exec "$STUBS/curl.base" "\$@" ;;
  *) exec "$STUBS/curl.base" "\$@" ;;
esac
STUB
  cat > "$STUBS/gh" <<STUB
#!/usr/bin/env bash
S="$AGENT_STATE"
case "\$1 \$2" in
  "pr list")
    if [[ "\$*" == *"--state all"* ]]; then
      echo "gh \$*" >> "$CALLS"
      jq -s '.' "\$S"/*.json 2>/dev/null || echo '[]'
      exit 0
    fi ;;
  "pr close")
    if [ -f "\$S/\$3.json" ]; then
      echo "gh \$*" >> "$CALLS"
      c=""; for ((i = 1; i <= \$#; i++)); do [ "\${!i}" = --comment ] && { j=\$((i + 1)); c="\${!j}"; }; done
      echo "\$c" >> "\$S/comment-\$3"
      jq '.state = "CLOSED"' "\$S/\$3.json" > "\$S/tmp" && mv "\$S/tmp" "\$S/\$3.json"
      exit 0
    fi ;;
  "api -X")
    if [[ "\$3" == POST && "\$4" == repos/*/issues/*/labels ]]; then
      echo "gh \$*" >> "$CALLS"
      n="\${4#*/issues/}"; n="\${n%%/*}"
      jq '.labels += [{"name": "demo-reset"}]' "\$S/\$n.json" > "\$S/tmp" && mv "\$S/tmp" "\$S/\$n.json"
      exit 0
    fi ;;
esac
exec "$STUBS/gh.base" "\$@"
STUB
  chmod +x "$STUBS"/kubectl "$STUBS"/curl "$STUBS"/gh
}

setup() {
  make_reset_fixture
}

# add_agent_pr N STATE [labelled] : a PR on an agent/* branch
add_agent_pr() {
  local labels='[]'
  [[ "${3:-}" == labelled ]] && labels='[{"name":"demo-reset"}]'
  jq -n --argjson n "$1" --arg s "$2" --argjson l "$labels" \
    '{number: $n, state: $s, headRefName: "agent/checkout-aaaaaaa-bbbbbbb", labels: $l}' > "$AGENT_STATE/$1.json"
}
agent_state() { jq -r .state "$AGENT_STATE/$1.json"; }
agent_labelled() { jq -e '[.labels[].name] | index("demo-reset") != null' "$AGENT_STATE/$1.json" >/dev/null; }

reset() { ( cd "$FIXTURE" && "$RESET" "$@" ); }

# other_commit MSG FILE KEY VALUE : another pusher edits origin directly (yq, as the scripts do).
other_commit() {
  "$REAL_GIT" -C "$OTHER" pull -q --ff-only origin build/demo
  V="$4" yq -i "$3 = strenv(V)" "$OTHER/$2"
  "$REAL_GIT" -C "$OTHER" commit -q -am "$1"
  "$REAL_GIT" -C "$OTHER" push -q origin HEAD:refs/heads/build/demo
}
cfg_value() { origin_file "$CFG" | yq -r .data.UPSTREAM_TIMEOUT_MS; }
cv_value() { origin_file "$ROLL" | yq -r '.spec.template.metadata.annotations["example.dev/config-version"]'; }
tag_value() { origin_file "$KUST" | yq -r '.images[0].newTag'; }
calls_at() { grep -n "$1" "$CALLS" | head -n1 | cut -d: -f1; }

@test "reset never raises autonomy" {
  for rung in 1 2; do
    run reset "$rung"
    [ "$status" -eq 0 ]
    [ "$(tip_autonomy .level)" = "suggest" ]
  done
  # rung 3 from suggest: refuses, level untouched
  run reset 3
  [ "$status" -eq 6 ]
  [ "$(tip_autonomy .level)" = "suggest" ]
  # rung 3 from propose keeps propose
  seed_autonomy propose
  run reset 3
  [ "$status" -eq 0 ]
  [ "$(tip_autonomy .level)" = "propose" ]
  # no direct commit on the tracked branch promoted anything
  [ -z "$(origin_log | grep 'autonomy): promote' || true)" ]
}

@test "reset lowers act to the rung's starting level, one demotion per step" {
  seed_autonomy act
  run reset 1
  [ "$status" -eq 0 ]
  [ "$(tip_autonomy .level)" = "suggest" ]
  origin_log | grep -q 'demote act to propose'
  origin_log | grep -q 'demote propose to suggest'
}

@test "reset deletes notified annotation" {
  run reset 2
  [ "$status" -eq 0 ]
  grep -q '^NOTIFIED_CLEAR$' "$CALLS"
}

@test "reset closes open agent PRs with the demo-reset label" {
  add_agent_pr 41 OPEN
  add_agent_pr 42 MERGED
  add_agent_pr 43 CLOSED labelled
  run reset 2
  [ "$status" -eq 0 ]
  [ "$(agent_state 41)" = "CLOSED" ]
  [ "$(cat "$AGENT_STATE/comment-41")" = "reset for rehearsal" ]
  agent_labelled 41
  # a merged test PR keeps its state but stops counting on panel 4
  [ "$(agent_state 42)" = "MERGED" ]
  agent_labelled 42
  # already labelled and closed: not touched again
  run ! grep -q 'issues/43/labels' "$CALLS"
  [ ! -e "$AGENT_STATE/comment-43" ]
  # labelled before it was closed, so the reconciler never sees it unlabelled
  [ "$(calls_at 'issues/41/labels')" -lt "$(calls_at 'pr close 41')" ]
}

@test "reset-demo disarms before seeding" {
  other_commit "test: armed" "$CFG" .data.UPSTREAM_TIMEOUT_MS 200
  run reset demo
  [ "$status" -eq 0 ]
  mapfile -t subjects < <(origin_log)
  disarm_at=-1 pr242_at=-1
  for i in "${!subjects[@]}"; do # newest first
    case "${subjects[i]}" in
      "chore(demo): disarm checkout") ((disarm_at < 0)) && disarm_at=$i ;;
      PR-242:*) pr242_at=$i ;;
    esac
  done
  ((disarm_at >= 0)) && ((pr242_at >= 0))
  ((disarm_at > pr242_at)) # newest first: the disarm is older than the seeded PR-242
  [ "$(cfg_value)" = "200" ]  # pre-armed by seed-history, as rung 1 expects
}

@test "reset-demo restores stable tag v1.4.1" {
  other_commit "test: bumped" "$KUST" '.images[0].newTag' v1.4.3
  [ "$(tag_value)" = "v1.4.3" ]
  run reset demo
  [ "$status" -eq 0 ]
  [ "$(tag_value)" = "v1.4.1" ]
  [ "$(cv_value)" = "7" ]
}

@test "reset-rung-2 after a merged promotion opens a fresh promotion PR" {
  run promo ensure propose
  [ "$status" -eq 0 ]
  run promo merge 101 --admin
  [ "$status" -eq 0 ]
  [ "$(pr_state 101)" = "MERGED" ]
  [ "$(tip_autonomy .level)" = "propose" ]
  run reset 2
  [ "$status" -eq 0 ]
  [ "$(tip_autonomy .level)" = "suggest" ]
  [ "$(open_pr_count)" -eq 1 ]
  [[ "$(branch_of 102)" =~ ^promote/propose-[0-9]{14}-[a-z0-9]{4}$ ]]
  [ "$(pr_state 102)" = "OPEN" ]
}

leftover_promotion_closed_by() { # TARGET
  seed_autonomy propose
  run promo ensure act
  [ "$status" -eq 0 ]
  [ "$(open_pr_count)" -eq 1 ]
  run reset "$1"
  [ "$status" -eq 0 ]
  [ "$(open_pr_count)" -eq 0 ]
}

@test "reset-rung-1 closes a leftover promotion PR" { leftover_promotion_closed_by 1; }

@test "reset-demo closes a leftover promotion PR" { leftover_promotion_closed_by demo; }

@test "reset-rung-3 from act lowers to propose and opens a fresh act promotion PR" {
  seed_autonomy act
  run reset 3
  [ "$status" -eq 0 ]
  [ "$(tip_autonomy .level)" = "propose" ]
  [ "$(open_pr_count)" -eq 1 ]
  [[ "$(branch_of 101)" =~ ^promote/act- ]]
  [ "$(autonomy_at "refs/heads/$(branch_of 101)" .level)" = "act" ]
}

@test "reset-rung-3 from suggest opens the propose promotion PR and exits 6 without pushing a level change" {
  before="$(origin_tip)"
  run reset 3
  [ "$status" -eq 6 ]
  [[ "$output" == *"rung 3 needs propose first: approve and merge PR #101, then run reset-rung-3 again"* ]]
  [ "$(open_pr_count)" -eq 1 ]
  [[ "$(branch_of 101)" =~ ^promote/propose- ]]
  [ "$(origin_tip)" = "$before" ]
  [ "$(tip_autonomy .level)" = "suggest" ]
}

@test "reset-demo re-seeds with keep_live_hours=0" {
  run reset demo
  [ "$status" -eq 0 ]
  grep -qx '/seed?reset=true&keep_live_hours=0' "$STUBS/seed-urls.log"
}

@test "reset-rung-1 seeds the history but keeps the timeline" {
  run reset 1
  [ "$status" -eq 0 ]
  grep -qx '/seed?reset=false&keep_live_hours=0' "$STUBS/seed-urls.log"
  run ! grep -q 'reset=true' "$STUBS/seed-urls.log"
}

@test "reset-rung-1 and reset-demo hand the seeded cause to demo-rung-1 in .operator/last-rearm" {
  for target in 1 demo; do
    rm -f "$FIXTURE/.operator/last-rearm"
    run reset "$target"
    [ "$status" -eq 0 ]
    f="$FIXTURE/.operator/last-rearm"
    [ -s "$f" ]
    cause="$(sed -n 's/^cause: //p' "$f")"
    [[ "$cause" =~ ^[0-9a-f]{40}$ ]]
    [ "$("$REAL_GIT" --git-dir="$ORIGIN" diff-tree --no-commit-id --name-only -r "$cause")" = "$CFG" ]
    [[ "$(sed -n 's/^change_ref: //p' "$f")" =~ ^CHG- ]]
  done
}

@test "reset-rung-2 and 3 leave the config disarmed and seed nothing" {
  run reset 2
  [ "$status" -eq 0 ]
  [ "$(cfg_value)" = "2000" ]
  [ ! -e "$STUBS/seed-urls.log" ]
}

@test "reset runs bridge-hooks-clear and restarts the bridge" {
  : > "$STUBS/BRIDGE_ENV"
  run reset 2
  [ "$status" -eq 0 ]
  grep -q '^HOOKS_CLEARED$' "$CALLS"
  grep -q '^BRIDGE_POD_DELETE$' "$CALLS"
}

@test "reset deletes the bridge pod to clear its registry" {
  run reset 1
  [ "$status" -eq 0 ]
  grep -q '^BRIDGE_POD_DELETE$' "$CALLS"
}

@test "reset rolls pods that still read 200 when Git is already disarmed" {
  : > "$STUBS/STALE_PODS"
  run reset 2
  [ "$status" -eq 0 ]
  origin_log | grep -q 'roll checkout pods'
  [ "$(cv_value)" = "7" ]
  [ "$(cfg_value)" = "2000" ]
}

@test "reset prints the elapsed seconds" {
  run reset 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"reset 2 done in "[0-9]*"s"* ]]
}

@test "reset refuses an unknown or missing target" {
  run reset 4
  [ "$status" -ne 0 ]
  run reset
  [ "$status" -ne 0 ]
}

# ------------------------------------------------------------ the wall clock
# date stub: prints the fixed time FAKE_EPOCH, logs every call.
date_stub() {
  local real_date
  real_date="$(command -v date)"
  cat > "$STUBS/date" <<STUB
#!/usr/bin/env bash
echo "date \$*" >> "$BATS_TEST_TMPDIR/date.log"
for a in "\$@"; do [ "\$a" = -d ] && exec "$real_date" "\$@"; done
exec "$real_date" -d "@\$FAKE_EPOCH" "\$@"
STUB
  chmod +x "$STUBS/date"
}

# run_all_resets_at EPOCH : every reset from the same start, at one fixed time; prints the calls
# with the promotion branch names (UTC stamp and suffix) and temp file names blanked.
run_all_resets_at() {
  rm -rf "${BATS_TEST_TMPDIR:?}"/*
  make_reset_fixture
  date_stub
  export FAKE_EPOCH="$1"
  add_agent_pr 41 OPEN
  seed_autonomy act
  : > "$CALLS"
  local t
  for t in 3 2 1 demo; do
    reset "$t" >/dev/null 2>&1 || [ "$t" = 3 ]
  done
  sed -E 's#promote/(propose|act)-[0-9]{14}-[a-z0-9]{4}#promote/\1-STAMP#g; s#--body-file [^ ]+#--body-file TMP#' "$CALLS"
}

@test "reset never reads the wall clock" {
  # 2026-11-03 03:00 UTC and 15:00 UTC
  a="$(run_all_resets_at 1793674800)"
  b="$(run_all_resets_at 1793718000)"
  [ -n "$a" ]
  [ "$a" = "$b" ]
}
