#!/usr/bin/env bats
# Tests for scripts/retarget.sh. GitHub is a local bare repo, the operator clone and the main
# checkout are real clones of it (the main checkout carries a copy of scripts/, demo.env and
# the gitops files, as on the real machine), and kubectl, gh, curl, the ruleset script and
# promotion-pr.sh are stubs that log to $CALLS. No cluster, no network.

load helpers
load ops_helpers

BASE=build/demo
SCRATCH=rehearse/main-sim

setup() {
  make_retarget_fixture
}

make_retarget_fixture() {
  make_ops_fixture
  export CALLS STUBS ORIGIN FIXTURE REAL_GIT
  # Put the tooling, demo.env and the gitops files on origin's build/demo.
  "$REAL_GIT" -C "$OTHER" pull -q --ff-only origin "$BASE"
  mkdir -p "$OTHER/bridge/deploy" "$OTHER/.github"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/gitops" "$OTHER/"
  cp "$REPO_ROOT/demo.env" "$REPO_ROOT/versions.env" "$OTHER/"
  cp "$REPO_ROOT/bridge/deploy/deployment.yaml" "$OTHER/bridge/deploy/"
  # the fixture starts on build/demo, whatever branch the live files track (main after Run C)
  sed -i 's|^TRACKED_BRANCH=.*|TRACKED_BRANCH=build/demo|' "$OTHER/demo.env"
  grep -rl 'targetRevision: main$' "$OTHER/gitops" | xargs -r sed -i 's|targetRevision: main$|targetRevision: build/demo|'
  sed -i 's|{name: TRACKED_BRANCH, value: [^}]*}|{name: TRACKED_BRANCH, value: build/demo}|' "$OTHER/bridge/deploy/deployment.yaml"
  unset TRACKED_BRANCH
  printf '/aiops/autonomy.yaml @org/board\n/policy/ @org/board\n/.github/ @org/board\n' > "$OTHER/.github/CODEOWNERS"
  printf '.env\n.kube/\n.operator/\n' > "$OTHER/.gitignore"
  "$REAL_GIT" -C "$OTHER" add -A
  "$REAL_GIT" -C "$OTHER" commit -q -m "seed tooling"
  "$REAL_GIT" -C "$OTHER" push -q origin "HEAD:refs/heads/$BASE"
  "$REAL_GIT" -C "$OP" pull -q --ff-only origin "$BASE"
  # The main checkout is a clone too.
  rm -rf "$FIXTURE"
  "$REAL_GIT" clone -q --branch "$BASE" "$ORIGIN" "$FIXTURE" 2>/dev/null
  _ops_git_identity "$FIXTURE"
  mkdir -p "$FIXTURE/.kube"
  printf 'OPERATOR_DIR=%s\n' "$OP" > "$FIXTURE/.env"
  _retarget_stubs
  export RETARGET_PROMOTION_SCRIPT="$STUBS/promotion-pr.sh" RETARGET_RULESET_SCRIPT="$STUBS/github-ruleset.sh"
  export RETARGET_WAIT_S=6
  unset RETARGET_RULESET_MODE RETARGET_GITHUB_PREFLIGHT
}

_retarget_stubs() {
  # Argo CD, as seen through kubectl: until the root app is applied every Application reports
  # a stale branch; after it, the branch named in the main checkout's gitops file. A file
  # STUCK in $STUBS keeps them stale. The bridge Deployment reads the main checkout's file.
  cat > "$STUBS/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "kubectl $*" >> "$CALLS"
newrev() { # FILE -> the targetRevision in the main checkout, or stale
  if [ -e "$STUBS/APPLIED" ] && [ ! -e "$STUBS/STUCK" ]; then
    sed -n 's/^ *targetRevision: *//p' "$FIXTURE/$1" | head -1
  else echo stale; fi
}
case "$*" in
  *"config current-context"*) echo kind-argoconna26 ;;
  *"apply -f gitops/root.yaml"*) : > "$STUBS/APPLIED" ;;
  *"annotate application"*) ;;
  *"get application "*)
    app=$(awk '{for (i = 1; i <= NF; i++) if ($i == "application") { print $(i + 1); exit }}' <<<"$*")
    file=gitops/apps/$app.yaml; [ "$app" = root ] && file=gitops/root.yaml
    rev=$(newrev "$file")
    sha=$("$REAL_GIT" --git-dir="$ORIGIN" rev-parse "refs/heads/$rev" 2>/dev/null || echo 0000)
    jq -n --arg r "$rev" --arg sha "$sha" \
      '{spec: {source: {targetRevision: $r}}, status: {sync: {status: "Synced", revision: $sha}, health: {status: "Healthy"}}}' ;;
  *"get deployment bridge"*)
    b=stale
    if [ -e "$STUBS/APPLIED" ]; then
      b=$(sed -n 's/.*name: TRACKED_BRANCH, value: *\([^}]*\)}.*/\1/p' "$FIXTURE/bridge/deploy/deployment.yaml")
    fi
    jq -n --arg b "$b" '{metadata: {generation: 3}, status: {observedGeneration: 3},
      spec: {template: {spec: {containers: [{env: [{name: "TRACKED_BRANCH", value: $b}]}]}}}}' ;;
  *"rollout status"*) ;;
  *) echo "kubectl stub: unexpected $*" >&2; exit 1 ;;
esac
STUB
  cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS"
echo '{"test_hooks_active": false}'
STUB
  # gh: open PRs from open-prs.json; rules per branch from rules-<branch with / as _>.json,
  # else a good default; CODEOWNERS unless NO_CODEOWNERS exists.
  cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$CALLS"
case "$1 $2" in
  "pr list") cat "$STUBS/open-prs.json" 2>/dev/null || echo '[]' ;;
  "pr close") ;;
  "api repos/argo-multiverse-labs/argoconna26/rules/branches/"*)
    b="${2##*/rules/branches/}"; f="$STUBS/rules-${b//\//_}.json"
    if [ -f "$f" ]; then cat "$f"; else
      echo '[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"pull_request","parameters":{"require_code_owner_review":false}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"policy-check","integration_id":15368}]}}]'
    fi ;;
  "api repos/argo-multiverse-labs/argoconna26/contents/.github/CODEOWNERS"*)
    [ -e "$STUBS/NO_CODEOWNERS" ] && exit 1
    echo '{"name":"CODEOWNERS"}' ;;
  *) echo "gh stub: unexpected: $*" >&2; exit 1 ;;
esac
STUB
  # the ruleset script: live-mode reads LIVE_MODE (default minimal-policy-check, matching the
  # default rules above); anything else is logged as RULESET.
  cat > "$STUBS/github-ruleset.sh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = live-mode ]; then echo "live-mode" >> "$CALLS"; cat "$STUBS/LIVE_MODE" 2>/dev/null || echo minimal-policy-check; exit 0; fi
echo "RULESET $*" >> "$CALLS"
STUB
  cat > "$STUBS/promotion-pr.sh" <<'STUB'
#!/usr/bin/env bash
echo "PROMO $*" >> "$CALLS"
STUB
  chmod +x "$STUBS"/*
}

retarget() { ( cd "$FIXTURE" && "$FIXTURE/scripts/retarget.sh" "$@" ); }

# commit_on BRANCH PATH CONTENT : one commit on origin's BRANCH writing PATH
commit_on() {
  "$REAL_GIT" -C "$OTHER" fetch -q origin
  "$REAL_GIT" -C "$OTHER" checkout -q -B work "origin/$1"
  mkdir -p "$OTHER/$(dirname "$2")"
  printf '%s\n' "$3" > "$OTHER/$2"
  "$REAL_GIT" -C "$OTHER" add "$2"
  "$REAL_GIT" -C "$OTHER" commit -q -m "change $2"
  "$REAL_GIT" -C "$OTHER" push -q origin "HEAD:refs/heads/$1"
}

GOOD_RULES='[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"pull_request","parameters":{"require_code_owner_review":true}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"policy-check","integration_id":15368}]}}]'


# make_branch NAME : a branch on origin at build/demo's tip
make_branch() { "$REAL_GIT" --git-dir="$ORIGIN" branch "$1" "refs/heads/$BASE"; }
origin_show() { "$REAL_GIT" --git-dir="$ORIGIN" show "refs/heads/$1:$2"; }
tip() { "$REAL_GIT" --git-dir="$ORIGIN" rev-parse "refs/heads/$1"; }
main_branch() { "$REAL_GIT" -C "$FIXTURE" rev-parse --abbrev-ref HEAD; }
line_of() { grep -n -m1 -- "$1" "$CALLS" | cut -d: -f1; }

@test "retarget changes every targetRevision and TRACKED_BRANCH on the destination branch" {
  make_branch "$SCRATCH"
  before="$(tip "$BASE")"
  run retarget "$SCRATCH"
  [ "$status" -eq 0 ]
  # exactly one forward commit on the scratch branch; the old branch is untouched
  [ "$(tip "$BASE")" = "$before" ]
  [ "$("$REAL_GIT" --git-dir="$ORIGIN" rev-list --count "$BASE..$SCRATCH")" = 1 ]
  [ "$("$REAL_GIT" --git-dir="$ORIGIN" log -1 --format=%s "$SCRATCH")" = "chore(demo): track $SCRATCH" ]
  for f in root.yaml apps/bridge.yaml apps/cdevents-sim.yaml apps/checkout.yaml apps/dashboards.yaml apps/loadgen.yaml apps/pricing.yaml; do
    [ "$(origin_show "$SCRATCH" gitops/$f | sed -n 's/^ *targetRevision: *//p')" = "$SCRATCH" ]
  done
  origin_show "$SCRATCH" demo.env | grep -qx "TRACKED_BRANCH=$SCRATCH"
  origin_show "$SCRATCH" demo.env | grep -q "^RULESET_BRANCHES=.*,$SCRATCH\$"
  origin_show "$SCRATCH" bridge/deploy/deployment.yaml | grep -q "name: TRACKED_BRANCH, value: $SCRATCH}"
  # nothing else changed in the commit
  [ "$("$REAL_GIT" --git-dir="$ORIGIN" diff --name-only "$BASE" "$SCRATCH" | wc -l)" = 9 ]
  # the main checkout moved too, clean, and reads the same demo.env
  [ "$(main_branch)" = "$SCRATCH" ]
  [ -z "$("$REAL_GIT" -C "$FIXTURE" status --porcelain)" ]
  grep -qx "TRACKED_BRANCH=$SCRATCH" "$FIXTURE/demo.env"
  ! grep -q FORBIDDEN "$CALLS"
}

@test "retarget refuses a branch that doesn't contain HEAD" {
  make_branch "$SCRATCH"
  # build/demo moves on after the scratch branch was cut
  echo more > "$OTHER/more.txt"
  "$REAL_GIT" -C "$OTHER" add more.txt
  "$REAL_GIT" -C "$OTHER" commit -q -m "newer work"
  "$REAL_GIT" -C "$OTHER" push -q origin "HEAD:refs/heads/$BASE"
  run retarget "$SCRATCH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never a rewind"* ]]
  ! grep -q '^PUSH' "$CALLS"
  ! grep -q 'apply -f' "$CALLS"
  [ "$(main_branch)" = "$BASE" ]
}

@test "retarget refuses a branch that is not on origin, an odd name, a dirty clone and a dirty checkout" {
  run retarget does/not-exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"not on origin"* ]]
  run retarget 'bad;name'
  [ "$status" -ne 0 ]
  [[ "$output" == *"plain branch name"* ]]
  make_branch "$SCRATCH"
  echo x > "$OP/dirty.txt"
  run retarget "$SCRATCH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"operator clone"*"not clean"* ]]
  rm "$OP/dirty.txt"
  echo x > "$FIXTURE/dirty.txt"
  run retarget "$SCRATCH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"main checkout is not clean"* ]]
  ! grep -q '^PUSH' "$CALLS"
  ! grep -q 'apply -f' "$CALLS"
}

@test "retarget re-applies the root app and waits for every child on the new branch" {
  make_branch "$SCRATCH"
  run retarget "$SCRATCH"
  [ "$status" -eq 0 ]
  push=$(line_of '^PUSH')
  apply=$(line_of 'apply -f gitops/root.yaml')
  firstwait=$(line_of 'get application')
  [ -n "$push" ] && [ -n "$apply" ] && [ -n "$firstwait" ]
  [ "$push" -lt "$apply" ]
  [ "$apply" -lt "$firstwait" ]
  for app in root bridge cdevents-sim checkout dashboards loadgen pricing; do
    grep -q "get application $app " "$CALLS"
  done
  # the bridge rollout is waited for after the apps
  [ "$(line_of 'get deployment bridge')" -gt "$(line_of 'get application pricing')" ]
  grep -q 'rollout status deployment/bridge' "$CALLS"
  # the bridge setting travels in git; no bridge-env Secret is touched
  ! grep -q 'bridge-env' "$CALLS"
}

@test "retarget stops when the Applications never follow, before the ruleset" {
  make_branch "$SCRATCH"
  : > "$STUBS/STUCK"
  RETARGET_WAIT_S=3 run retarget "$SCRATCH"
  [ "$status" -eq 4 ]
  grep -q 'apply -f gitops/root.yaml' "$CALLS"
  ! grep -q '^RULESET' "$CALLS"
  ! grep -q '^PROMO' "$CALLS"
}

@test "retarget re-applies the ruleset and checks the required policy-check" {
  make_branch "$SCRATCH"
  run retarget "$SCRATCH"
  [ "$status" -eq 0 ]
  grep -qx 'RULESET apply --minimal' "$CALLS"
  [ "$(line_of '^RULESET')" -gt "$(line_of 'rollout status')" ]
  # every RULESET_BRANCHES entry is read back, the new one included
  for b in build/demo main "$SCRATCH"; do
    grep -q "gh api repos/argo-multiverse-labs/argoconna26/rules/branches/$b\$" "$CALLS"
  done
  grep -q 'contents/.github/CODEOWNERS?ref='"$SCRATCH" "$CALLS"
  [[ "$output" == *"github-admin and github-runtime preflight sections: not run here"* ]]
}

@test "retarget fails when the new branch lacks the required policy-check, before the promotion PRs" {
  make_branch "$SCRATCH"
  echo '[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"pull_request","parameters":{}}]' \
    > "$STUBS/rules-rehearse_main-sim.json"
  echo '[{"number":7,"headRefName":"promote/propose-20261102-abcd","baseRefName":"build/demo"}]' > "$STUBS/open-prs.json"
  run retarget "$SCRATCH"
  [ "$status" -ne 0 ]
  # caught before any change now (the destination must be protected before Argo CD follows it)
  [[ "$output" == *"not protected yet"*"policy-check"* ]]
  ! grep -q '^PUSH' "$CALLS"
  ! grep -q 'pr close' "$CALLS"
  ! grep -q '^PROMO' "$CALLS"
}

@test "retarget in full mode applies without --minimal and wants code-owner review" {
  make_branch "$SCRATCH"
  RETARGET_RULESET_MODE=full run retarget "$SCRATCH"
  [ "$status" -ne 0 ]
  grep -qx 'RULESET apply' "$CALLS"
  [[ "$output" == *"lacks"* ]]
}

@test "retarget fails when CODEOWNERS is missing on the new branch" {
  make_branch "$SCRATCH"
  : > "$STUBS/NO_CODEOWNERS"
  run retarget "$SCRATCH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CODEOWNERS not found"* ]]
  ! grep -q '^PROMO' "$CALLS"
}

@test "retarget recreates open promotion PRs against the new base" {
  make_branch "$SCRATCH"
  cat > "$STUBS/open-prs.json" <<'JSON'
[{"number":7,"headRefName":"promote/propose-20261102-abcd","baseRefName":"build/demo"},
 {"number":9,"headRefName":"agent/fix-1","baseRefName":"build/demo"},
 {"number":11,"headRefName":"promote/act-20261103-wxyz","baseRefName":"rehearse/main-sim"}]
JSON
  run retarget "$SCRATCH"
  [ "$status" -eq 0 ]
  grep -q 'gh pr close 7 ' "$CALLS"
  grep -qx "PROMO ensure propose" "$CALLS"
  # not a promotion PR, and a promotion PR already on the new base: left alone
  ! grep -q 'gh pr close 9 ' "$CALLS"
  ! grep -q 'gh pr close 11 ' "$CALLS"
  [ "$(grep -c '^PROMO' "$CALLS")" = 1 ]
  # after the ruleset, closing before ensure
  [ "$(line_of 'gh pr close 7')" -gt "$(line_of '^RULESET')" ]
  [ "$(line_of '^PROMO')" -gt "$(line_of 'gh pr close 7')" ]
}

@test "retarget back after commits on the scratch branch" {
  make_branch "$SCRATCH"
  run retarget "$SCRATCH"
  [ "$status" -eq 0 ]
  # bot merges and a rearm land on the scratch branch; the old branch is then fast-forwarded
  "$REAL_GIT" -C "$OTHER" fetch -q origin
  "$REAL_GIT" -C "$OTHER" checkout -q -B scratch-work "origin/$SCRATCH"
  for n in merge rearm; do
    echo "$n" > "$OTHER/$n.txt"
    "$REAL_GIT" -C "$OTHER" add "$n.txt"
    "$REAL_GIT" -C "$OTHER" commit -q -m "chore: $n"
  done
  "$REAL_GIT" -C "$OTHER" push -q origin "HEAD:refs/heads/$SCRATCH"
  "$REAL_GIT" -C "$OTHER" push -q origin "HEAD:refs/heads/$BASE"
  rm -f "$STUBS/APPLIED"
  : > "$CALLS"
  run retarget "$BASE"
  [ "$status" -eq 0 ]
  for f in root.yaml apps/checkout.yaml apps/pricing.yaml; do
    [ "$(origin_show "$BASE" gitops/$f | sed -n 's/^ *targetRevision: *//p')" = "$BASE" ]
  done
  origin_show "$BASE" demo.env | grep -qx "TRACKED_BRANCH=$BASE"
  origin_show "$BASE" bridge/deploy/deployment.yaml | grep -q "name: TRACKED_BRANCH, value: $BASE}"
  # the rearm and merge commits are still there: it was a forward move
  origin_show "$BASE" rearm.txt >/dev/null
  [ "$(main_branch)" = "$BASE" ]
  grep -q 'apply -f gitops/root.yaml' "$CALLS"
}

@test "retarget run again after finishing changes nothing on origin and still re-applies" {
  make_branch "$SCRATCH"
  run retarget "$SCRATCH"
  [ "$status" -eq 0 ]
  after="$(tip "$SCRATCH")"
  rm -f "$STUBS/APPLIED"
  : > "$CALLS"
  run retarget "$SCRATCH"
  [ "$status" -eq 0 ]
  [ "$(tip "$SCRATCH")" = "$after" ]
  ! grep -q '^PUSH' "$CALLS"
  grep -q 'apply -f gitops/root.yaml' "$CALLS"
}

@test "retarget resumes when the commit reached origin but the main checkout did not switch" {
  make_branch "$SCRATCH"
  run retarget "$SCRATCH"
  [ "$status" -eq 0 ]
  after="$(tip "$SCRATCH")"
  # as if the run died after the push: the main checkout back on the old branch
  "$REAL_GIT" -C "$FIXTURE" switch -q "$BASE"
  rm -f "$STUBS/APPLIED"
  : > "$CALLS"
  run retarget "$SCRATCH"
  [ "$status" -eq 0 ]
  [ "$(tip "$SCRATCH")" = "$after" ]
  [ "$(main_branch)" = "$SCRATCH" ]
  grep -q 'apply -f gitops/root.yaml' "$CALLS"
}

@test "retarget refuses a destination the live rulesets don't protect yet, before any commit" {
  make_branch "$SCRATCH"
  echo '[{"type":"pull_request","parameters":{}}]' > "$STUBS/rules-rehearse_main-sim.json"
  run retarget "$SCRATCH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not protected yet"* ]]
  ! grep -q '^PUSH' "$CALLS"
  ! grep -q 'apply -f' "$CALLS"
  ! grep -q '^RULESET' "$CALLS"
  [ "$("$REAL_GIT" --git-dir="$ORIGIN" rev-list --count "$BASE..$SCRATCH")" = 0 ]
}

@test "retarget refuses a destination whose autonomy level is above the tracked branch's" {
  commit_on "$BASE" aiops/autonomy.yaml 'level: suggest'
  make_branch "$SCRATCH"
  commit_on "$SCRATCH" aiops/autonomy.yaml 'level: act'
  "$REAL_GIT" -C "$FIXTURE" pull -q --ff-only origin "$BASE"
  run retarget "$SCRATCH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"autonomy"*"act"*"suggest"* ]]
  ! grep -q '^PUSH' "$CALLS"
  ! grep -q 'apply -f' "$CALLS"
}

@test "retarget accepts a destination at the same or a lower autonomy level" {
  commit_on "$BASE" aiops/autonomy.yaml 'level: propose'
  make_branch "$SCRATCH"
  "$REAL_GIT" -C "$FIXTURE" pull -q --ff-only origin "$BASE"
  run retarget "$SCRATCH"
  [ "$status" -eq 0 ]
}

@test "retarget refuses a destination that changes code-owned paths the tracked branch lacks" {
  make_branch "$SCRATCH"
  commit_on "$SCRATCH" policy/extra.rego 'package autofix'
  run retarget "$SCRATCH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"code-owned"*"policy/extra.rego"* ]]
  ! grep -q '^PUSH' "$CALLS"
  ! grep -q 'apply -f' "$CALLS"
}

@test "retarget defaults to the live ruleset mode and keeps live code-owner review" {
  make_branch "$SCRATCH"
  echo policy-check > "$STUBS/LIVE_MODE"
  for b in build_demo main rehearse_main-sim; do echo "$GOOD_RULES" > "$STUBS/rules-$b.json"; done
  run retarget "$SCRATCH"
  [ "$status" -eq 0 ]
  grep -qx 'RULESET apply' "$CALLS"
  ! grep -q 'RULESET apply --minimal' "$CALLS"
}

@test "retarget refuses RETARGET_RULESET_MODE=minimal while code-owner review is live, before any commit" {
  make_branch "$SCRATCH"
  echo policy-check > "$STUBS/LIVE_MODE"
  for b in build_demo main rehearse_main-sim; do echo "$GOOD_RULES" > "$STUBS/rules-$b.json"; done
  RETARGET_RULESET_MODE=minimal run retarget "$SCRATCH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"code-owner review"* ]]
  ! grep -q '^PUSH' "$CALLS"
  ! grep -q '^RULESET' "$CALLS"
}

@test "make retarget needs BRANCH" {
  run make -C "$REPO_ROOT" retarget
  [ "$status" -ne 0 ]
  [[ "$output" == *"BRANCH=<branch> is required"* ]]
}
