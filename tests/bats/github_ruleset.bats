#!/usr/bin/env bats
# Tests for scripts/github-ruleset.sh (gh is a stub holding rulesets in a directory; git push is not exercised)

load helpers

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  STATE="$BATS_TEST_TMPDIR/state"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$STATE/rulesets"
  : > "$CALLS"
  make_stub "$STUBS" gh 'echo "gh $*" >> "'"$CALLS"'"
    S="'"$STATE"'"
    if [ "$1" = label ]; then echo "label $3" >> "$S/labels"; exit 0; fi
    [ "$1" = api ] || { echo "unexpected: $*" >&2; exit 1; }
    shift; method=GET; path=""; input=0
    while [ $# -gt 0 ]; do
      case "$1" in -X) method="$2"; shift 2 ;; --input) input=1; shift 2 ;; -H) shift 2 ;; *) path="$1"; shift ;; esac
    done
    body=""; [ "$input" = 1 ] && body="$(cat)"
    case "$method $path" in
      "GET repos/argo-multiverse-labs/argoconna26/rulesets")
        jq -s "map({id,name,enforcement})" "$S"/rulesets/*.json 2>/dev/null || echo "[]" ;;
      "GET repos/argo-multiverse-labs/argoconna26/rulesets/"*) cat "$S/rulesets/${path##*/}.json" ;;
      "POST repos/argo-multiverse-labs/argoconna26/rulesets")
        n=$(( $(cat "$S/next" 2>/dev/null || echo 100) + 1 )); echo $n > "$S/next"
        jq --argjson id $n ". + {id:\$id}" <<<"$body" > "$S/rulesets/$n.json"; echo "{\"id\":$n}" ;;
      "PUT repos/argo-multiverse-labs/argoconna26/rulesets/"*)
        id="${path##*/}"; [ -f "$S/rulesets/$id.json" ] || exit 1
        jq --argjson id "$id" ". + {id:\$id}" <<<"$body" > "$S/rulesets/$id.json"; echo "{\"id\":$id}" ;;
      "DELETE repos/argo-multiverse-labs/argoconna26/rulesets/"*) rm -f "$S/rulesets/${path##*/}.json" ;;
      *) echo "unexpected: $method $path" >&2; exit 1 ;;
    esac'
  export TOOLS_BIN="$STUBS"
  SCRIPT="$REPO_ROOT/scripts/github-ruleset.sh"
}

count() { ls "$STATE"/rulesets/*.json 2>/dev/null | wc -l; }
rs() { jq -c "$2" "$(grep -l "\"name\": *\"$1\"" "$STATE"/rulesets/*.json | head -1)"; }

@test "show with no rulesets lists none" {
  run "$SCRIPT" show
  [ "$status" -eq 0 ]
  [[ "$output" == *'"rulesets": []'* || "$output" == *'[]'* ]]
}

@test "apply --minimal creates exactly the three rulesets" {
  run "$SCRIPT" apply --minimal
  [ "$status" -eq 0 ]
  [ "$(count)" -eq 3 ]
  for n in argoconna26-integrity argoconna26-tracked argoconna26-promote; do
    grep -l "\"name\": *\"$n\"" "$STATE"/rulesets/*.json >/dev/null
  done
}

@test "integrity: both branches, deletion and non_fast_forward, no bypass for anyone" {
  "$SCRIPT" apply --minimal
  [ "$(rs argoconna26-integrity '.bypass_actors|length')" = "0" ]
  [ "$(rs argoconna26-integrity '.conditions.ref_name.include')" = '["refs/heads/build/demo","refs/heads/main"]' ]
  [ "$(rs argoconna26-integrity '[.rules[].type]|sort')" = '["deletion","non_fast_forward"]' ]
}

@test "tracked: pull request rule, no code-owner review with --minimal, admin role bypass only" {
  "$SCRIPT" apply --minimal
  [ "$(rs argoconna26-tracked '.bypass_actors')" = '[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]' ]
  [ "$(rs argoconna26-tracked '.rules[0].type')" = '"pull_request"' ]
  [ "$(rs argoconna26-tracked '.rules[0].parameters.require_code_owner_review')" = "false" ]
  [ "$(rs argoconna26-tracked '.rules[0].parameters.required_approving_review_count')" = "0" ]
  [ "$(rs argoconna26-tracked '.rules[0].parameters.require_last_push_approval')" = "false" ]
  [ "$(rs argoconna26-tracked '.rules[0].parameters.dismiss_stale_reviews_on_push')" = "true" ]
  [ "$(rs argoconna26-tracked '.conditions.ref_name.include|length')" = "2" ]
}

@test "tracked: full apply turns code-owner review on" {
  "$SCRIPT" apply
  [ "$(rs argoconna26-tracked '.rules[0].parameters.require_code_owner_review')" = "true" ]
}

@test "promote: promote/* creation, update and deletion, admin role bypass only" {
  "$SCRIPT" apply --minimal
  [ "$(rs argoconna26-promote '.conditions.ref_name.include')" = '["refs/heads/promote/*"]' ]
  [ "$(rs argoconna26-promote '[.rules[].type]|sort')" = '["creation","deletion","update"]' ]
  [ "$(rs argoconna26-promote '.bypass_actors|length')" = "1" ]
}

@test "apply is idempotent: a second run updates in place, same ids, still three" {
  "$SCRIPT" apply --minimal
  ids1="$(ls "$STATE"/rulesets)"
  run "$SCRIPT" apply --minimal
  [ "$status" -eq 0 ]
  [ "$(ls "$STATE"/rulesets)" = "$ids1" ]
  [ "$(count)" -eq 3 ]
  grep -q 'PUT' "$CALLS"
}

@test "apply creates both labels, idempotently (--force)" {
  "$SCRIPT" apply --minimal
  grep -q 'label create demo-reset' "$CALLS"
  grep -q 'label create policy-negative-test' "$CALLS"
  grep -q -- '--force' "$CALLS"
}

@test "no bypass actor is ever the App, a team or a user" {
  "$SCRIPT" apply
  run jq -s '[.[].bypass_actors[].actor_type] | unique' "$STATE"/rulesets/*.json
  [ "$output" = '["RepositoryRole"]' ] || [ "$output" = '[]' ] || [[ "$(echo $output | tr -d ' \n')" == '["RepositoryRole"]' ]]
}

@test "apply --spike adds a temporary ruleset on one rehearse branch with the slice-5 rules" {
  "$SCRIPT" apply --minimal
  run "$SCRIPT" apply --spike rehearse/merge-spike
  [ "$status" -eq 0 ]
  [ "$(count)" -eq 4 ]
  [ "$(rs argoconna26-spike '.conditions.ref_name.include')" = '["refs/heads/rehearse/merge-spike"]' ]
  [ "$(rs argoconna26-spike '[.rules[].type]|sort')" = '["pull_request","required_status_checks"]' ]
  [ "$(rs argoconna26-spike '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks')" = '[{"context":"policy-check","integration_id":15368}]' ]
  [ "$(rs argoconna26-spike '.rules[]|select(.type=="pull_request")|.parameters.require_code_owner_review')" = "true" ]
  # the merge spike showed require_last_push_approval blocks every App-authored PR; off by default
  [ "$(rs argoconna26-spike '.rules[]|select(.type=="pull_request")|.parameters.require_last_push_approval')" = "false" ]
}

@test "RULESET_LAST_PUSH_APPROVAL=true turns the last-push rule back on in tracked and spike" {
  RULESET_LAST_PUSH_APPROVAL=true "$SCRIPT" apply --minimal
  RULESET_LAST_PUSH_APPROVAL=true "$SCRIPT" apply --spike rehearse/merge-spike
  [ "$(rs argoconna26-tracked '.rules[0].parameters.require_last_push_approval')" = "true" ]
  [ "$(rs argoconna26-spike '.rules[]|select(.type=="pull_request")|.parameters.require_last_push_approval')" = "true" ]
}

@test "RULESET_LAST_PUSH_APPROVAL accepts only true or false" {
  RULESET_LAST_PUSH_APPROVAL=yes run "$SCRIPT" apply --minimal
  [ "$status" -ne 0 ]
  [ "$(count)" -eq 0 ]
}

@test "tracked: no required status check unless --with-policy-check" {
  "$SCRIPT" apply
  [ "$(rs argoconna26-tracked '[.rules[].type]')" = '["pull_request"]' ]
}

@test "apply --with-policy-check adds the required policy-check to tracked, code-owner review on" {
  "$SCRIPT" apply --with-policy-check
  [ "$(rs argoconna26-tracked '[.rules[].type]|sort')" = '["pull_request","required_status_checks"]' ]
  [ "$(rs argoconna26-tracked '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks')" = '[{"context":"policy-check","integration_id":15368}]' ]
  [ "$(rs argoconna26-tracked '.rules[]|select(.type=="pull_request")|.parameters.require_code_owner_review')" = "true" ]
}

@test "live_mode reads the tracked ruleset back, so verify-integrity's cleanup keeps what is live" {
  "$SCRIPT" apply --minimal
  run env GH_RULESET_LIB=1 bash -c ". '$SCRIPT'; load_env; BRANCHES=\$RULESET_BRANCHES; live_mode"
  [ "$output" = "minimal" ]
  "$SCRIPT" apply
  run env GH_RULESET_LIB=1 bash -c ". '$SCRIPT'; load_env; BRANCHES=\$RULESET_BRANCHES; live_mode"
  [ "$output" = "full" ]
  "$SCRIPT" apply --with-policy-check
  run env GH_RULESET_LIB=1 bash -c ". '$SCRIPT'; load_env; BRANCHES=\$RULESET_BRANCHES; live_mode"
  [ "$output" = "policy-check" ]
}

@test "apply --minimal --with-policy-check adds the required check with code-owner review off" {
  "$SCRIPT" apply --minimal --with-policy-check
  [ "$(rs argoconna26-tracked '[.rules[].type]|sort')" = '["pull_request","required_status_checks"]' ]
  [ "$(rs argoconna26-tracked '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks')" = '[{"context":"policy-check","integration_id":15368}]' ]
  [ "$(rs argoconna26-tracked '.rules[]|select(.type=="pull_request")|.parameters.require_code_owner_review')" = "false" ]
  run env GH_RULESET_LIB=1 bash -c ". '$SCRIPT'; load_env; BRANCHES=\$RULESET_BRANCHES; live_mode"
  [ "$output" = "minimal-policy-check" ]
}

@test "force_push_refused_by_integrity needs GH013 and the non-fast-forward rule text" {
  run env GH_RULESET_LIB=1 bash -c ". '$SCRIPT'; force_push_refused_by_integrity <<<'remote: error: GH013: Repository rule violations found for refs/heads/x.
remote: - Cannot force-push to this branch'"
  [ "$status" -eq 0 ]
  # a pull-request-only refusal (tracked, if the admin bypass were lost) is not the integrity rule
  run env GH_RULESET_LIB=1 bash -c ". '$SCRIPT'; force_push_refused_by_integrity <<<'remote: error: GH013: Repository rule violations found for refs/heads/x.
remote: - Changes must be made through a pull request.'"
  [ "$status" -ne 0 ]
  # a generic non-fast-forward rejection (no ruleset) does not count
  run env GH_RULESET_LIB=1 bash -c ". '$SCRIPT'; force_push_refused_by_integrity <<<' ! [remote rejected] x -> x (non-fast-forward)'"
  [ "$status" -ne 0 ]
  run env GH_RULESET_LIB=1 bash -c ". '$SCRIPT'; force_push_refused_by_integrity <<<' ! [remote rejected] x -> x (protected branch hook declined)'"
  [ "$status" -ne 0 ]
}

@test "apply --spike refuses a listed or non-rehearse branch" {
  run "$SCRIPT" apply --spike main
  [ "$status" -ne 0 ]
  run "$SCRIPT" apply --spike build/demo
  [ "$status" -ne 0 ]
  [ "$(count)" -eq 0 ]
}

@test "apply --spike-remove deletes only the spike ruleset and is a no-op when absent" {
  "$SCRIPT" apply --minimal
  "$SCRIPT" apply --spike rehearse/merge-spike
  run "$SCRIPT" apply --spike-remove
  [ "$status" -eq 0 ]
  [ "$(count)" -eq 3 ]
  run "$SCRIPT" apply --spike-remove
  [ "$status" -eq 0 ]
  [ "$(count)" -eq 3 ]
}

@test "show prints the three rulesets with bypass and refs, nothing else" {
  "$SCRIPT" apply --minimal
  run "$SCRIPT" show
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" -eq 3 ]
  [ "$(jq -r '.[]|select(.name=="argoconna26-integrity")|.bypass_actors|length' <<<"$output")" = "0" ]
}

@test "unknown mode fails with usage" {
  run "$SCRIPT" frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *usage* ]]
}

@test "script file has no token or login strings" {
  ! grep -Eiq 'ghp_|gho_|github_pat_' "$SCRIPT"
}
