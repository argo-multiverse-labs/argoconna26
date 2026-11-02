#!/usr/bin/env bats
# Tests for the spec section 9 checks added to scripts/preflight.sh in Task 6.5.
# kubectl, curl, gh, uv and systemctl are stubs reading files under $STATE; nothing touches a
# cluster, Prometheus, systemd or GitHub. The "healthy" state is what every test starts from.

load helpers

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$FIXTURE"
  mkdir -p "$FIXTURE/.kube"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE/rulesets" "$STATE/ns"
  export STATE

  make_stub "$STUBS" kubectl 'S="'"$STATE"'"
    case "$*" in
      "config current-context") echo kind-argoconna26 ;;
      "config get-contexts -o name") cat "$S/contexts" ;;
      *"auth can-i"*)
        case "$*" in
          *"get secret/"*|*"list secrets"*) if [ -e "$S/can-i-leak" ]; then echo yes; else echo no; fi ;;
          *"create pods"*) echo no ;;
          *) echo yes ;;
        esac ;;
      *"get --raw=/readyz"*) echo ok ;;
      *"get namespaces"*) cat "$S/namespaces.json" ;;
      *"get namespace "*) ;;
      *"get pods -n demo -l app=checkout"*) cat "$S/checkout-pods.json" ;;
      *"get pods -n "*) a="$*"; n="${a#*-n }"; n="${n%% *}"; if [ -f "$S/ns/$n.json" ]; then cat "$S/ns/$n.json"; else echo "{\"items\":[]}"; fi ;;
      *"get jobs -n "*) echo "{\"items\":[]}" ;;
      *"get deployment bridge"*) cat "$S/bridge-deploy.json" ;;
      *"get applications.argoproj.io"*) cat "$S/apps.json" ;;
      *) echo "kubectl stub: unexpected $*" >&2; exit 1 ;;
    esac'
  make_stub "$STUBS" kind 'echo argoconna26'
  make_stub "$STUBS" curl 'S="'"$STATE"'"
    case "$*" in
      *checkout_slo_target_percent*) cat "$S/slo.json" ;;
      *checkout_requests_total*) cat "$S/rate.json" ;;
      *checkout_config_upstream_timeout_ms*) cat "$S/gauge.json" ;;
      */status) [ -f "$S/status.json" ] && cat "$S/status.json" || exit 7 ;;
      *) exit 7 ;;
    esac'
  make_stub "$STUBS" gh 'S="'"$STATE"'"
    if [ "$1 $2" = "pr list" ]; then cat "$S/prs.json"; exit 0; fi
    [ "$1" = api ] || exit 0
    path=""; for a in "$@"; do case "$a" in repos/*|orgs/*|user) path="${a%%\?*}" ;; esac; done
    R=repos/argo-multiverse-labs/argoconna26
    case "$path" in
      $R) cat "$S/repo.json" ;;
      $R/rulesets) jq -s "map({id,name})" "$S"/rulesets/*.json ;;
      $R/rulesets/*) cat "$S/rulesets/${path##*/}.json" ;;
      $R/rules/branches/*) cat "$S/rules.json" ;;
      $R/labels/*) [ ! -e "$S/nolabel-${path##*/}" ] ;;
      $R/contents/aiops/autonomy.yaml) cat "$S/autonomy.yaml" ;;
      $R/contents/.github/CODEOWNERS) echo CODEOWNERS ;;
      # GitHub answers 204 with no body unless the repository media type is asked for.
      orgs/*/teams/*/repos/*) [ -f "$S/team-repo.json" ] || exit 1
        case "$*" in *application/vnd.github.v3.repository+json*) cat "$S/team-repo.json" ;; esac ;;
      orgs/*/teams/*/memberships/*) [ -f "$S/membership.json" ] && cat "$S/membership.json" || exit 1 ;;
      user) echo login ;;
      *) echo "gh stub: unexpected $*" >&2; exit 1 ;;
    esac'
  make_stub "$STUBS" uv '[ -f "'"$STATE"'/app-check.json" ] && cat "'"$STATE"'/app-check.json" || exit 1'
  for t in yq docker; do command -v "$t" >/dev/null || make_stub "$STUBS" "$t" 'exit 0'; done
  export PATH="$STUBS:$PATH" TOOLS_BIN="$STUBS"
  export PREFLIGHT_FLEET_WAIT_S=0
  unset STAGE_APPROVER_LOGIN PREFLIGHT_L5B GH_TOKEN
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run" SYSTEMD_USER_DIR="$BATS_TEST_TMPDIR/units"
  mkdir -p "$XDG_RUNTIME_DIR"

  # preflight.sh with only the named sections live: only.sh "fleet job" 3 --armed
  cat >"$BATS_TEST_TMPDIR/only.sh" <<EOF
#!/usr/bin/env bash
cd "$FIXTURE"
. "$REPO_ROOT/scripts/preflight.sh"
keep=" \$1 "; shift
for s in \$(compgen -A function section_ | sed s/section_//); do
  [[ \$keep == *" \$s "* ]] || eval "section_\$s() { :; }"
done
main "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/only.sh"
  ONLY="$BATS_TEST_TMPDIR/only.sh"

  healthy_cluster
  healthy_github
}

# ----------------------------------------------------------------- state builders
healthy_cluster() {
  echo kind-argoconna26 >"$STATE/contexts"
  jq -n '{items: [("argocd","demo","kube-system","aiops","argo-rollouts","monitoring","default")|{metadata:{name:.}}]}' >"$STATE/namespaces.json"
  checkout_pods v1.4.1 0 0
  echo '{"data":{"result":[{"metric":{"pod":"checkout-a"},"value":[0,"2000"]},{"metric":{"pod":"checkout-b"},"value":[0,"2000"]}]}}' >"$STATE/gauge.json"
  echo '{"data":{"result":[{"value":[0,"99.9"]}]}}' >"$STATE/rate.json"
  echo '{"data":{"result":[{"value":[0,"99"]}]}}' >"$STATE/slo.json"
  echo '{"spec":{"replicas":1},"status":{"readyReplicas":1}}' >"$STATE/bridge-deploy.json"
  echo '{"github_token_ok":true,"holmes_reachable":true,"dry_forge":false,"test_hooks_active":false}' >"$STATE/status.json"
  jq -n '{items: [{metadata:{name:"root"},status:{sync:{status:"Synced"},health:{status:"Healthy"}}},
                  {metadata:{name:"checkout"},status:{sync:{status:"Synced"},health:{status:"Healthy"}}}]}' >"$STATE/apps.json"
}

# checkout_pods TAG RESTARTS_A RESTARTS_B
checkout_pods() {
  jq -n --arg t "$1" --argjson a "$2" --argjson b "$3" '{items: [
    {metadata:{name:"checkout-a"},spec:{containers:[{image:("checkout:"+$t)}]},
     status:{phase:"Running",conditions:[{type:"Ready",status:"True"}],containerStatuses:[{restartCount:$a}]}},
    {metadata:{name:"checkout-b"},spec:{containers:[{image:("checkout:"+$t)}]},
     status:{phase:"Running",conditions:[{type:"Ready",status:"True"}],containerStatuses:[{restartCount:$b}]}}]}' >"$STATE/checkout-pods.json"
}

healthy_github() {
  echo '{"allow_auto_merge":true,"security_and_analysis":{"secret_scanning_push_protection":{"status":"enabled"}}}' >"$STATE/repo.json"
  local both='["refs/heads/build/demo","refs/heads/main"]'
  local admin='[{"actor_type":"RepositoryRole","actor_id":5,"bypass_mode":"always"}]'
  local chk='{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"policy-check","integration_id":15368}]}}'
  jq -n --argjson i "$both" '{id:1,name:"argoconna26-integrity",conditions:{ref_name:{include:$i}},bypass_actors:[],rules:[{type:"deletion"},{type:"non_fast_forward"}]}' >"$STATE/rulesets/1.json"
  jq -n --argjson i "$both" --argjson b "$admin" --argjson c "$chk" '{id:2,name:"argoconna26-tracked",conditions:{ref_name:{include:$i}},bypass_actors:$b,
    rules:[{type:"pull_request",parameters:{require_code_owner_review:true}},$c]}' >"$STATE/rulesets/2.json"
  jq -n --argjson b "$admin" '{id:3,name:"argoconna26-promote",conditions:{ref_name:{include:["refs/heads/promote/*"]}},bypass_actors:$b,rules:[{type:"creation"},{type:"update"},{type:"deletion"}]}' >"$STATE/rulesets/3.json"
  jq -n --argjson c "$chk" '[{type:"pull_request",parameters:{require_code_owner_review:true}},$c]' >"$STATE/rules.json"
  # GitHub's real shape: the Write role is "write", with permissions.push true.
  echo '{"role_name":"write","permissions":{"admin":false,"maintain":false,"push":true,"triage":true,"pull":true}}' >"$STATE/team-repo.json"
  echo '{"state":"active"}' >"$STATE/membership.json"
  autonomy suggest
  prs '[]'
  echo '{"token_minted":true,"permissions":{"contents":"write","pull_requests":"write","metadata":"read","checks":"read"}}' >"$STATE/app-check.json"
}

# Before L5b: code-owner review is off on the tracked branch and the team does not exist yet.
pre_l5b() {
  jq '.rules |= map(if .type == "pull_request" then .parameters.require_code_owner_review = false else . end)' \
    "$STATE/rulesets/2.json" >"$STATE/t" && mv "$STATE/t" "$STATE/rulesets/2.json"
  jq 'map(if .type == "pull_request" then .parameters.require_code_owner_review = false else . end)' \
    "$STATE/rules.json" >"$STATE/t" && mv "$STATE/t" "$STATE/rules.json"
  rm -f "$STATE/team-repo.json" "$STATE/membership.json"
}

autonomy() { # LEVEL [APPROVED_BY]
  printf 'level: %s\npromotion:\n  approved_by: %s\n' "$1" "${2:-null}" >"$STATE/autonomy.yaml"
}

prs() { echo "$1" >"$STATE/prs.json"; }
pr() { printf '{"number":%s,"headRefName":"%s"}' "$1" "$2"; }

# ------------------------------------------------------------------- fleet (Review Focus 1)
@test "preflight passes the fleet section on a disarmed fleet at the stable image" {
  run "$ONLY" fleet 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS]"*"fleet:"*"success rate"* ]]
  [[ "$output" == *"stable image v1.4.1"* ]]
}

@test "preflight fails when any checkout pod reports 200" {
  jq '.data.result[1].value[1] = "200"' "$STATE/gauge.json" >"$STATE/t" && mv "$STATE/t" "$STATE/gauge.json"
  run "$ONLY" fleet 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"fleet"*"checkout-b"*"=200"* ]]
}

@test "preflight fails when success rate is below the SLO" {
  echo '{"data":{"result":[{"value":[0,"93.5"]}]}}' >"$STATE/rate.json"
  run "$ONLY" fleet 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"fleet"*"93.5"*"below"*"99"* ]]
}

@test "preflight fails when a checkout pod has no gauge series" {
  jq '.data.result |= [.[0]]' "$STATE/gauge.json" >"$STATE/t" && mv "$STATE/t" "$STATE/gauge.json"
  run "$ONLY" fleet 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"fleet"*"no checkout_config_upstream_timeout_ms series"* ]]
}

@test "preflight fails when the success-rate query is empty" {
  echo '{"data":{"result":[]}}' >"$STATE/rate.json"
  run "$ONLY" fleet 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"fleet"*"empty or NaN"* ]]
}

@test "preflight fails on a NaN success rate (no traffic)" {
  echo '{"data":{"result":[{"value":[0,"NaN"]}]}}' >"$STATE/rate.json"
  run "$ONLY" fleet 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty or NaN"* ]]
}

@test "fleet fails rungs 1 and 2 when a checkout pod runs another image, but not rung 3" {
  checkout_pods v1.4.2 0 0
  run "$ONLY" fleet 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"not on the stable image v1.4.1"*"checkout-a"* ]]
  run "$ONLY" fleet 3 --pre-promotion
  [ "$status" -eq 0 ]
}

@test "fleet fails when a checkout pod has restarted since the last disarm" {
  checkout_pods v1.4.1 0 2
  run "$ONLY" fleet 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"restarted"*"checkout-b"* ]]
}

@test "fleet does nothing without a rung" {
  echo '{"data":{"result":[]}}' >"$STATE/rate.json"
  run "$ONLY" fleet
  [ "$status" -eq 0 ]
}

# ----------------------------------------------------------------- job (Task 5.5 section)
install_unit() { (cd "$FIXTURE" && "$REPO_ROOT/scripts/night.sh" job-install >/dev/null 2>&1); }

@test "preflight 3 --armed fails when the job unit isn't installed" {
  run "$ONLY" job 3 --armed
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"job:"*"argoconna26-rearm.service is not installed"* ]]
}

@test "preflight 3 --armed fails when cluster_lock is held" {
  make_stub "$STUBS" systemctl 'exit 0'
  install_unit
  ( exec 9>>"$FIXTURE/.kube/cluster.lock"; flock -n 9; sleep 20 ) &
  holder=$!
  wait_file "$FIXTURE/.kube/cluster.lock"
  sleep 0.5
  echo "4242 make rearm" >"$FIXTURE/.kube/cluster.lock"
  run "$ONLY" job 3 --armed
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"job: cluster_lock is held by: 4242 make rearm"* ]]
}

@test "job passes with the unit installed, the lock free and no job.env; the lock only matters when armed" {
  make_stub "$STUBS" systemctl 'exit 0'
  install_unit
  run "$ONLY" job 3 --armed
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS]"*"cluster_lock is free"* ]]
  [[ "$output" == *"[PASS]"*"PATH resolves kind, kubectl, yq, uv and docker"* ]]
  run "$ONLY" job 3 --pre-promotion
  [ "$status" -eq 0 ]
  [[ "$output" != *"cluster_lock"* ]]
}

@test "job fails on a job.env left over from an earlier run" {
  make_stub "$STUBS" systemctl 'exit 0'
  install_unit
  mkdir -p "$XDG_RUNTIME_DIR/argoconna26"
  echo GH_TOKEN=x >"$XDG_RUNTIME_DIR/argoconna26/job.env"
  run "$ONLY" job 3 --armed
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"job.env is left over"* ]]
  [[ "$output" != *"GH_TOKEN=x"* ]]
}

@test "job fails when the rendered PATH does not resolve the pinned tools" {
  make_stub "$STUBS" systemctl 'exit 0'
  install_unit
  sed -i 's|^Environment="PATH=.*"$|Environment="PATH=/usr/bin:/bin"|' "$SYSTEMD_USER_DIR/argoconna26-rearm.service"
  run "$ONLY" job 3 --armed
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"PATH does not resolve the pinned tools"* ]]
}

@test "job fails when the unit points at another checkout" {
  make_stub "$STUBS" systemctl 'exit 0'
  install_unit
  sed -i 's|^WorkingDirectory=.*|WorkingDirectory=/somewhere/else|' "$SYSTEMD_USER_DIR/argoconna26-rearm.service"
  run "$ONLY" job 3 --pre-promotion
  [ "$status" -eq 1 ]
  [[ "$output" == *"WorkingDirectory is '/somewhere/else'"* ]]
}

@test "job is skipped for rungs 1 and 2 and inside the unit (--job-run)" {
  run "$ONLY" job 2
  [ "$status" -eq 0 ]
  GH_TOKEN=x run "$ONLY" job 3 --armed --job-run
  [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------- apps
@test "apps fails naming an Application that is not Synced and Healthy" {
  jq '.items[1].status.sync.status = "OutOfSync" | .items[1].status.health.status = "Degraded"' "$STATE/apps.json" >"$STATE/t" && mv "$STATE/t" "$STATE/apps.json"
  run "$ONLY" apps
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"checkout (OutOfSync/Degraded)"* ]]
}

@test "apps passes when every Application is Synced and Healthy" {
  run "$ONLY" apps
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS]"*"all 2 Argo CD Applications"* ]]
}

# ------------------------------------------------------------------------- bridge
@test "a bridge scaled to 0 exits 1 and names the bridge" {
  echo '{"spec":{"replicas":0},"status":{}}' >"$STATE/bridge-deploy.json"
  rm "$STATE/status.json"
  run "$ONLY" bridge 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"bridge: Deployment has 0 of 0 replicas ready"* ]]
  [[ "$output" == *"[FAIL]"*"bridge: /status does not answer"* ]]
}

@test "bridge fails on a dry forge, an unreachable HolmesGPT and a missing GitHub token" {
  echo '{"github_token_ok":false,"holmes_reachable":false,"dry_forge":true}' >"$STATE/status.json"
  run "$ONLY" bridge 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"github_token_ok is not true"* ]]
  [[ "$output" == *"holmes_reachable is not true"* ]]
  [[ "$output" == *"dry_forge is not false"* ]]
}

@test "bridge passes with a ready Deployment and a real, reachable status" {
  run "$ONLY" bridge 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS]"*"dry_forge is false"* ]]
}

# ------------------------------------------------------------------------- holmes
@test "holmes passes while the ServiceAccount cannot read Secrets" {
  run "$ONLY" holmes 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS]"*"holmes:"* ]]
}

@test "holmes fails when the ServiceAccount can read Secrets" {
  touch "$STATE/can-i-leak"
  run "$ONLY" holmes 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"holmes:"*"can-i get secret/"*"yes"* ]]
}

# --------------------------------------------------------------------------- pods
@test "pods checks every namespace, including demo and aiops, and fails on an unready pod" {
  jq -n '{items:[{metadata:{name:"ok"},status:{phase:"Running",conditions:[{type:"Ready",status:"True"}]}}]}' >"$STATE/ns/demo.json"
  jq -n '{items:[{metadata:{name:"bridge-x"},status:{phase:"Running",conditions:[{type:"Ready",status:"False"}]}}]}' >"$STATE/ns/aiops.json"
  for n in argocd argo-rollouts monitoring kube-system; do cp "$STATE/ns/demo.json" "$STATE/ns/$n.json"; done
  run "$ONLY" pods 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"[PASS]"*"every pod Ready in demo"* ]]
  [[ "$output" == *"[FAIL]"*"pods not Ready in aiops: bridge-x"* ]]
  [[ "$output" == *"[PASS]"*"every pod Ready in kube-system"* ]]
  [[ "$output" != *"in default"* ]]
}

@test "pods fails when a required namespace has no pods" {
  run "$ONLY" pods 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"pods not Ready in demo: none running"* ]]
}

# --------------------------------------------------------------------------- local
@test "local fails on a second kube context, a missing hook and too little disk" {
  printf 'kind-argoconna26\nprod-eu\n' >"$STATE/contexts"
  PREFLIGHT_MIN_FREE_GB=99999999 OPERATOR_DIR="$BATS_TEST_TMPDIR/no-op-clone" run "$ONLY" local 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"holds 2 contexts"* ]]
  [[ "$output" == *"[FAIL]"*"operator clone"* ]]
  [[ "$output" == *"[FAIL]"*"KB free"* ]]
}

@test "local passes with both hooks, one context and disk space" {
  mkdir -p "$BATS_TEST_TMPDIR/op/.git/hooks"
  printf '#!/bin/sh\n' >"$BATS_TEST_TMPDIR/op/.git/hooks/pre-commit"; chmod +x "$BATS_TEST_TMPDIR/op/.git/hooks/pre-commit"
  printf '#!/bin/sh\n' >"$FIXTURE/.git/hooks/pre-commit"; chmod +x "$FIXTURE/.git/hooks/pre-commit"
  OPERATOR_DIR="$BATS_TEST_TMPDIR/op" run "$ONLY" local 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"one context"* ]]
}

# --------------------------------------------------- github-runtime: autonomy, promotion state
@test "runtime: rung 1 needs suggest" {
  run "$ONLY" github_runtime 1
  [ "$status" -eq 0 ]
  autonomy propose
  run "$ONLY" github_runtime 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"autonomy on build/demo is 'propose', expected suggest"* ]]
}

@test "runtime: rung 2 needs suggest and exactly one open propose promotion PR" {
  run "$ONLY" github_runtime 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected exactly one open propose promotion PR, found 0"* ]]
  prs "[$(pr 5 promote/propose-20261102-ab12)]"
  run "$ONLY" github_runtime 2
  [ "$status" -eq 0 ]
  prs "[$(pr 5 promote/propose-20261102-ab12),$(pr 6 promote/propose-20261102-cd34)]"
  run "$ONLY" github_runtime 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"found 2"* ]]
  prs "[$(pr 5 promote/act-20261102-ab12)]"
  run "$ONLY" github_runtime 2
  [ "$status" -eq 1 ]
}

@test "runtime: rung 3 --pre-promotion needs propose and exactly one open act promotion PR" {
  autonomy propose
  run "$ONLY" github_runtime 3 --pre-promotion
  [ "$status" -eq 1 ]
  prs "[$(pr 9 promote/act-20261102-ab12)]"
  run "$ONLY" github_runtime 3 --pre-promotion
  [ "$status" -eq 0 ]
}

@test "runtime: rung 3 --armed needs act with approved_by; admin-bypass warns" {
  autonomy act
  run "$ONLY" github_runtime 3 --armed
  [ "$status" -eq 1 ]
  [[ "$output" == *"no approved_by"* ]]
  autonomy act admin-bypass
  run "$ONLY" github_runtime 3 --armed
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN]"*"admin-bypass"* ]]
  autonomy act "promotion-board member (review https://example.test/r/1)"
  run "$ONLY" github_runtime 3 --armed
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS]"*"the promotion is approved"* ]]
  [[ "$output" != *"[WARN]"*"admin-bypass"* ]]
}

@test "runtime: rung 3 --armed fails unless the tracked branch requires policy-check" {
  autonomy act admin-bypass
  echo '[{"type":"pull_request","parameters":{}}]' >"$STATE/rules.json"
  run "$ONLY" github_runtime 3 --armed
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not require policy-check"* ]]
}

@test "runtime: without a rung nothing GitHub-side runs" {
  rm "$STATE/autonomy.yaml"
  run "$ONLY" github_runtime
  [ "$status" -eq 0 ]
}

# --------------------------------------------------------------- github-runtime: the App (L5b gate)
@test "runtime: the App check is a WARN deferred to L5b while code-owner review is off, and never calls uv" {
  pre_l5b
  rm "$STATE/app-check.json"
  run "$ONLY" github_runtime 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN]"*"App installation token and permissions not checked (deferred to L5b)"* ]]
}

@test "runtime: once L5b is live the App check is hard: a clean installation passes" {
  run "$ONLY" github_runtime 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS]"*"the App installation token mints"* ]]
  [[ "$output" == *"[PASS]"*"writes only contents and pull_requests"* ]]
}

@test "runtime: the App fails with workflows, administration or actions, or any other write" {
  for bad in '"workflows":"write"' '"administration":"read"' '"actions":"read"' '"issues":"write"'; do
    echo "{\"token_minted\":true,\"permissions\":{\"contents\":\"write\",\"pull_requests\":\"write\",$bad}}" >"$STATE/app-check.json"
    run "$ONLY" github_runtime 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"[FAIL]"*"permissions it must not"* ]]
  done
}

@test "runtime: the App fails when the token does not mint or the check cannot run" {
  echo '{"token_minted":false,"permissions":{"contents":"write"}}' >"$STATE/app-check.json"
  run "$ONLY" github_runtime 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"installation token does not mint"* ]]
  rm "$STATE/app-check.json"
  run "$ONLY" github_runtime 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"the App check failed"* ]]
}

@test "runtime: PREFLIGHT_L5B=1 makes the App check hard before the ruleset is applied, =0 keeps it deferred" {
  pre_l5b
  echo '{"token_minted":true,"permissions":{"contents":"write","workflows":"write"}}' >"$STATE/app-check.json"
  PREFLIGHT_L5B=1 run "$ONLY" github_runtime 1
  [ "$status" -eq 1 ]
  PREFLIGHT_L5B=0 run "$ONLY" github_runtime 1
  [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------- github-admin
@test "github-admin passes on the full ruleset set for rung 2" {
  STAGE_APPROVER_LOGIN=zq-login-x run "$ONLY" github_admin 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS]"*"allow_auto_merge"* ]]
  [[ "$output" == *"[PASS]"*"argoconna26-integrity covers"* ]]
  [[ "$output" == *"[PASS]"*"requires policy-check"* ]]
  [[ "$output" == *"[PASS]"*"requires code-owner review"* ]]
  [[ "$output" == *"[PASS]"*"membership of promotion-board is active"* ]]
  [[ "$output" != *"zq-login-x"* ]]
}

@test "github-admin passes when the team has GitHub's write role" {
  STAGE_APPROVER_LOGIN=zq-login-x run "$ONLY" github_admin 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS]"*"team promotion-board has push or higher"* ]]
}

@test "github-admin fails when the team only has read on the repo" {
  echo '{"role_name":"read","permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":true}}' >"$STATE/team-repo.json"
  STAGE_APPROVER_LOGIN=zq-login-x run "$ONLY" github_admin 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"team promotion-board has no push access"* ]]
}

@test "github-admin fails rung 2 when the stage approver's membership is pending" {
  echo '{"state":"pending"}' >"$STATE/membership.json"
  STAGE_APPROVER_LOGIN=zq-login-x run "$ONLY" github_admin 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"membership of promotion-board is 'pending', not active"* ]]
  [[ "$output" != *"zq-login-x"* ]]
}

@test "github-admin warns when STAGE_APPROVER_LOGIN is unset" {
  run "$ONLY" github_admin 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN]"*"no stage approver set; rung 2 needs admin bypass"* ]]
}

@test "github-admin does not look at the stage approver for 3 --armed" {
  STAGE_APPROVER_LOGIN=zq-login-x run "$ONLY" github_admin 3 --armed
  [ "$status" -eq 0 ]
  [[ "$output" != *"stage approver"* ]]
}

@test "github-admin is skipped for rung 1 and under --job-run" {
  rm "$STATE/repo.json"
  run "$ONLY" github_admin 1
  [ "$status" -eq 0 ]
  GH_TOKEN=x run "$ONLY" github_admin 2 --job-run
  [ "$status" -eq 0 ]
}

@test "github-admin before L5b: code-owner review, the team and the membership are WARN lines deferred to L5b" {
  pre_l5b
  STAGE_APPROVER_LOGIN=zq-login-x run "$ONLY" github_admin 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN]"*"does not require code-owner review (deferred to L5b)"* ]]
  [[ "$output" == *"[WARN]"*"has no push access to the repo (or does not exist) (deferred to L5b)"* ]]
  [[ "$output" == *"[WARN]"*"membership of promotion-board is 'absent', not active (deferred to L5b)"* ]]
  [[ "$output" == *"[PASS]"*"requires policy-check"* ]]
}

@test "github-admin: PREFLIGHT_L5B=1 turns the deferred checks into failures" {
  pre_l5b
  STAGE_APPROVER_LOGIN=zq-login-x PREFLIGHT_L5B=1 run "$ONLY" github_admin 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"does not require code-owner review"* ]]
  [[ "$output" == *"[FAIL]"*"has no push access"* ]]
}

@test "github-admin fails when the integrity ruleset has a bypass actor or misses a branch" {
  jq '.bypass_actors = [{"actor_type":"RepositoryRole","actor_id":5,"bypass_mode":"always"}]' "$STATE/rulesets/1.json" >"$STATE/t" && mv "$STATE/t" "$STATE/rulesets/1.json"
  run "$ONLY" github_admin 3 --armed
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"argoconna26-integrity must cover every RULESET_BRANCHES entry"* ]]
  healthy_github
  jq '.conditions.ref_name.include = ["refs/heads/main"]' "$STATE/rulesets/1.json" >"$STATE/t" && mv "$STATE/t" "$STATE/rulesets/1.json"
  run "$ONLY" github_admin 3 --armed
  [ "$status" -eq 1 ]
}

@test "github-admin fails when the App or the team can bypass the tracked ruleset" {
  jq '.bypass_actors += [{"actor_type":"Integration","actor_id":99,"bypass_mode":"always"}]' "$STATE/rulesets/2.json" >"$STATE/t" && mv "$STATE/t" "$STATE/rulesets/2.json"
  run "$ONLY" github_admin 3 --armed
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"bypass actor other than the admin role"* ]]
}

@test "github-admin fails without the required policy-check on the tracked ruleset" {
  jq '.rules |= map(select(.type != "required_status_checks"))' "$STATE/rulesets/2.json" >"$STATE/t" && mv "$STATE/t" "$STATE/rulesets/2.json"
  run "$ONLY" github_admin 3 --armed
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"does not require policy-check (integration 15368)"* ]]
}

@test "github-admin fails on the promote ruleset's extra bypass, a missing label and auto-merge off" {
  jq '.bypass_actors = []' "$STATE/rulesets/3.json" >"$STATE/t" && mv "$STATE/t" "$STATE/rulesets/3.json"
  touch "$STATE/nolabel-demo-reset"
  echo '{"allow_auto_merge":false,"security_and_analysis":{"secret_scanning_push_protection":{"status":"disabled"}}}' >"$STATE/repo.json"
  run "$ONLY" github_admin 3 --armed
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL]"*"argoconna26-promote must cover refs/heads/promote/*"* ]]
  [[ "$output" == *"[FAIL]"*"label demo-reset is missing"* ]]
  [[ "$output" == *"[FAIL]"*"allow_auto_merge is not on"* ]]
  [[ "$output" == *"[FAIL]"*"push protection is not enabled"* ]]
}
