#!/usr/bin/env bats
# Tests for scripts/git-ops.sh against a local bare-repo fixture (no network, no cluster).

load helpers
load ops_helpers

setup() {
  make_ops_fixture
}

@test "op_sync refuses dirty tree" {
  echo junk > "$OP/untracked.txt"
  run in_ops 'op_sync'
  [ "$status" -ne 0 ]
  [[ "$output" == *"not clean"* ]]
}

@test "op_sync refuses wrong branch" {
  "$REAL_GIT" -C "$OP" checkout -q -b elsewhere
  run in_ops 'op_sync'
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected 'build/demo'"* ]]
}

@test "op_sync refuses when the hook is missing" {
  rm "$OP/.git/hooks/pre-commit"
  run in_ops 'op_sync'
  [ "$status" -ne 0 ]
  [[ "$output" == *"pre-commit hook is missing"* ]]
}

@test "op_sync refuses to run in the main checkout" {
  export OPERATOR_DIR="$FIXTURE"
  printf 'OPERATOR_DIR=%s\n' "$FIXTURE" > "$FIXTURE/.env"
  run in_ops 'op_sync'
  [ "$status" -ne 0 ]
  [[ "$output" == *"operator clone is not set up"* ]]
}

@test "op_sync pulls what another pusher added" {
  echo x > "$OTHER/x.txt"
  "$REAL_GIT" -C "$OTHER" add x.txt
  "$REAL_GIT" -C "$OTHER" commit -q -m x
  "$REAL_GIT" -C "$OTHER" push -q origin HEAD:refs/heads/build/demo
  run in_ops 'op_sync'
  [ "$status" -eq 0 ]
  [ -f "$OP/x.txt" ]
}

@test "op_commit_push never force pushes" {
  export INTERFERE_ONCE=1   # forces the rejected-push, rebase, push-again path
  run in_ops 'config_value_set 200; op_commit_push "set 200" apps/checkout/config/checkout-config.yaml'
  [ "$status" -eq 0 ]
  ! grep -q FORBIDDEN "$CALLS"
  # the git stub refuses --force, -f and --no-verify: prove it would have
  run "$STUBS/git" push --force origin x
  [ "$status" -eq 99 ]
  run "$STUBS/git" commit --no-verify -m x
  [ "$status" -eq 99 ]
}

@test "op_commit_push retries after non-ff" {
  export INTERFERE_ONCE=1
  base="$(origin_tip)"
  run in_ops 'config_value_set 200; op_commit_push "set 200" apps/checkout/config/checkout-config.yaml'
  [ "$status" -eq 0 ]
  [ "$(grep -c '^PUSH' "$CALLS")" -eq 2 ]
  grep -q INTERFERED "$CALLS"
  # linear history: the other pusher's commit, then ours; no merge commit
  [ -z "$("$REAL_GIT" --git-dir="$ORIGIN" log --merges --format=%H refs/heads/build/demo)" ]
  [ "$("$REAL_GIT" --git-dir="$ORIGIN" rev-list --count "$base..refs/heads/build/demo")" -eq 2 ]
  [ "$(origin_log | head -1)" = "set 200" ]
  # the SHA it printed is the one that landed
  [ "${lines[-1]}" = "$(origin_tip)" ]
}

@test "op_commit_push gives up after three rejected pushes and says so" {
  # a hook that always rejects the push
  printf '#!/bin/sh\nexit 1\n' > "$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  run in_ops 'config_value_set 200; op_commit_push "set 200" apps/checkout/config/checkout-config.yaml'
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed after 3 attempts"* ]]
  [ "$(grep -c '^PUSH' "$CALLS")" -eq 3 ]
}

@test "op_commit_push inside a locked script succeeds" {
  cat > "$BATS_TEST_TMPDIR/locked.sh" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
. "$REPO_ROOT/scripts/git-ops.sh"
load_env
cluster_lock
config_value_set 200
op_commit_push "locked commit" apps/checkout/config/checkout-config.yaml
SCRIPT
  base="$(origin_tip)"
  run ops_run bash "$BATS_TEST_TMPDIR/locked.sh"
  [ "$status" -eq 0 ]
  [ "$("$REAL_GIT" --git-dir="$ORIGIN" rev-list --count "$base..refs/heads/build/demo")" -eq 1 ]
  [ "$(origin_log | head -1)" = "locked commit" ]
}

@test "op_commit_push refuses while another process holds the cluster lock" {
  ( cd "$FIXTURE" && exec 9>>.kube/cluster.lock && flock -n 9 && sleep 5 ) &
  holder=$!
  wait_file "$FIXTURE/.kube/cluster.lock"
  sleep 0.5
  run in_ops 'config_value_set 200; op_commit_push "blocked" apps/checkout/config/checkout-config.yaml'
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 5 ]
  [ "$(origin_log | head -1)" = "seed apps" ]
}

@test "config_version_bump increments by exactly one" {
  run in_ops 'config_version_bump'
  [ "$status" -eq 0 ]
  [ "$output" = "8" ]
  grep -q 'example.dev/config-version: "8"' "$OP/apps/checkout/deploy/rollout.yaml"
  run "$REAL_GIT" -C "$OP" diff --numstat
  [ "$output" = $'1\t1\tapps/checkout/deploy/rollout.yaml' ]
  run in_ops 'config_version_get'
  [ "$output" = "8" ]
}

@test "yaml_set preserves other keys and comments" {
  f="$BATS_TEST_TMPDIR/x.yaml"
  printf '# head\na: "1"\n# why b\nb: keep   # tail\nc:\n  d: x\n' > "$f"
  run in_ops "yaml_set '$f' .a 2"
  [ "$status" -eq 0 ]
  grep -q '^# head$' "$f"
  grep -q '^# why b$' "$f"
  grep -q '^a: "2"$' "$f"
  grep -q '^b: keep' "$f"
  grep -q '# tail' "$f"
  grep -q '^  d: x$' "$f"
}

@test "image_tag_get and image_tag_set work on the kustomization images list" {
  run in_ops 'image_tag_get'
  [ "$output" = "v1.4.1" ]
  run in_ops 'image_tag_set v1.4.2; image_tag_get'
  [ "$output" = "v1.4.2" ]
  run "$REAL_GIT" -C "$OP" diff --numstat
  [ "$output" = $'1\t1\tapps/checkout/kustomization.yaml' ]
}

@test "argo_refresh_and_wait uses kubectl only" {
  sha="$(origin_tip)"
  run in_ops "argo_refresh_and_wait checkout $sha 6"
  [ "$status" -eq 0 ]
  grep -q '^ANNOTATE checkout' "$CALLS"
  grep -q '^REV checkout' "$CALLS"
  ! grep -q 'ARGOCD CLI' "$CALLS"
  # and no script calls the argocd CLI
  ! grep -nE '(^|[^a-z_./-])argocd +(app|login|cluster|repo|proj)' "$REPO_ROOT"/scripts/git-ops.sh \
      "$REPO_ROOT"/scripts/{seed-history,rearm,fix,naive-revert}.sh
}

@test "argo_refresh_and_wait times out when the revision never arrives" {
  run in_ops "argo_refresh_and_wait checkout 0000000000000000000000000000000000000000 2"
  [ "$status" -eq 4 ]
}

@test "operator-clone warns and skips the hook when PRECOMMIT_HOOK_SRC is unset" {
  rm -rf "$OP"
  export OPERATOR_REMOTE="$ORIGIN"
  run ops_run "$REPO_ROOT/scripts/git-ops.sh" operator-clone
  [ "$status" -eq 0 ]
  [[ "$output" == *"PRECOMMIT_HOOK_SRC"*"skipping"* ]]
  [ -d "$OP/.git" ]
  [ ! -e "$OP/.git/hooks/pre-commit" ]
  # and op_sync then refuses, as before
  run in_ops 'op_sync'
  [ "$status" -ne 0 ]
  [[ "$output" == *"pre-commit hook is missing"* ]]
}

@test "operator-clone installs the hook and sets the credential helper for this clone only" {
  rm -rf "$OP"
  export OPERATOR_REMOTE="$ORIGIN"
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/hook-src"
  printf 'PRECOMMIT_HOOK_SRC=%s\nOPERATOR_DIR=%s\n' "$BATS_TEST_TMPDIR/hook-src" "$OP" > "$FIXTURE/.env"
  run ops_run "$REPO_ROOT/scripts/git-ops.sh" operator-clone
  [ "$status" -eq 0 ]
  [ -x "$OP/.git/hooks/pre-commit" ]
  run "$REAL_GIT" -C "$OP" config --local --get-all credential.https://github.com.helper
  [[ "$output" == *"!gh auth git-credential"* ]]
  # a second run changes nothing and does not duplicate the helper
  run ops_run "$REPO_ROOT/scripts/git-ops.sh" operator-clone
  [ "$status" -eq 0 ]
  [ "$("$REAL_GIT" -C "$OP" config --local --get-all credential.https://github.com.helper | wc -l)" -eq 2 ]
}

@test "operator git ignores a global insteadOf, so pushes keep the clone's own remote" {
  # Luke's ~/.gitconfig rewrites https://github.com/ to SSH; here a global rule rewrites the
  # fixture's origin to a path that does not exist.
  export HOME="$BATS_TEST_TMPDIR/home" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/home/.config"
  mkdir -p "$HOME"
  printf '[url "%s"]\n\tinsteadOf = %s\n[user]\n\tname = t\n\temail = t@example.invalid\n' \
    "$BATS_TEST_TMPDIR/nowhere.git" "$ORIGIN" > "$HOME/.gitconfig"
  # the rule is live for plain git
  [ "$("$REAL_GIT" -C "$OP" remote get-url --push origin)" = "$BATS_TEST_TMPDIR/nowhere.git" ]
  run in_ops 'op_sync && _og remote get-url --push origin && config_value_set 200 && op_commit_push "via own remote" apps/checkout/config/checkout-config.yaml'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$ORIGIN" ]
  [ "$(origin_log | head -1)" = "via own remote" ]
}

@test "op_sync refuses an origin whose push URL is not the expected remote" {
  "$REAL_GIT" -C "$OP" config remote.origin.pushurl git@github.com:someone/else.git
  run in_ops 'op_sync'
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected $ORIGIN"* ]]
}

@test "op_sync drops a local commit that never reached origin" {
  echo stale > "$OP/stale.txt"
  "$REAL_GIT" -C "$OP" add stale.txt
  "$REAL_GIT" -C "$OP" commit -q -m "unpushed bump"
  run in_ops 'op_sync && config_value_set 200 && op_commit_push "fresh" apps/checkout/config/checkout-config.yaml'
  [ "$status" -eq 0 ]
  [[ "$output" == *"dropped unpushed commit"* ]]
  run origin_log
  [ "${lines[0]}" = "fresh" ]
  [ "${lines[1]}" = "seed apps" ]
}

@test "a push that fails for good leaves the clone at origin's tip" {
  printf '#!/bin/sh\nexit 1\n' > "$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  run in_ops 'config_value_set 200; op_commit_push "set 200" apps/checkout/config/checkout-config.yaml'
  [ "$status" -ne 0 ]
  [ "$(op_head)" = "$(origin_tip)" ]
  [ -z "$("$REAL_GIT" -C "$OP" status --porcelain)" ]
}

@test "load_env refuses an .env that changes the push target" {
  local var
  for var in "TRACKED_BRANCH=main" "REPO_SLUG=someone/else" "OPERATOR_REMOTE=https://example.invalid/x.git"; do
    printf 'OPERATOR_DIR=%s\n%s\n' "$OP" "$var" > "$FIXTURE/.env"
    run in_ops 'echo loaded'
    [ "$status" -eq 3 ]
    [[ "$output" == *"refusing: .env sets ${var%%=*}"* ]]
  done
}
