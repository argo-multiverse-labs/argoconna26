#!/usr/bin/env bash
# Manage the repository rulesets this demo relies on. Needs a `gh` login with admin on the repo
# (the operator's own login; the GitHub App can never run this).
#
#   scripts/github-ruleset.sh apply [--minimal]        create or update the three standing rulesets
#                                                      and the two labels (idempotent: PUT by id)
#   scripts/github-ruleset.sh apply --spike BRANCH     add the temporary spike ruleset on one rehearse/* branch
#   scripts/github-ruleset.sh apply --spike-remove     delete the spike ruleset
#   scripts/github-ruleset.sh show                     print every ruleset, normalized, as JSON
#   scripts/github-ruleset.sh verify-integrity         prove a force-push to a listed branch is refused
#
# The standing rulesets (names and branch list come from demo.env; see docs/github-setup.md):
#   integrity  deletion + non_fast_forward on every RULESET_BRANCHES entry, bypass list EMPTY.
#   tracked    pull_request on the same branches; admin role may bypass (the operator's direct pushes).
#   promote    creation + update on refs/heads/promote/*; admin role may bypass.
# --minimal leaves code-owner review off in `tracked` (CODEOWNERS does not exist yet); a plain
# `apply` turns it on. Slice 5 adds required_status_checks to `tracked`.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ADMIN_ROLE_ID=5                  # GitHub's built-in "Admin" repository role
SPIKE_NAME=argoconna26-spike

usage() { die "usage: github-ruleset.sh apply [--minimal|--spike BRANCH|--spike-remove] | show | verify-integrity"; }

api() { gh api -H 'X-GitHub-Api-Version: 2022-11-28' "$@"; }

# refs_json BRANCH... : ["refs/heads/a","refs/heads/b"]
refs_json() { printf '%s\n' "$@" | jq -R '"refs/heads/" + .' | jq -s -c .; }

branches_array() { # RULESET_BRANCHES (or the override) -> one name per line
  local IFS=','
  # shellcheck disable=SC2086
  set -- $BRANCHES
  printf '%s\n' "$@" | sed '/^$/d'
}

admin_bypass="$(jq -n -c --argjson id "$ADMIN_ROLE_ID" '[{actor_id:$id, actor_type:"RepositoryRole", bypass_mode:"always"}]')"

# ruleset_body NAME INCLUDE_JSON BYPASS_JSON RULES_JSON
ruleset_body() {
  jq -n --arg name "$1" --argjson include "$2" --argjson bypass "$3" --argjson rules "$4" \
    '{name:$name, target:"branch", enforcement:"active",
      conditions:{ref_name:{include:$include, exclude:[]}},
      bypass_actors:$bypass, rules:$rules}'
}

pull_request_rule() { # CODE_OWNER(true|false)
  jq -n -c --argjson co "$1" '{type:"pull_request", parameters:{
      required_approving_review_count:0, dismiss_stale_reviews_on_push:true,
      require_code_owner_review:$co, require_last_push_approval:true,
      required_review_thread_resolution:false}}'
}

ruleset_id() { # NAME -> id or empty
  api "repos/$REPO_SLUG/rulesets" | jq -r --arg n "$1" '.[] | select(.name==$n) | .id' | head -1
}

put_ruleset() { # NAME BODY_JSON
  local name="$1" body="$2" id
  id="$(ruleset_id "$name")"
  if [[ -n "$id" ]]; then
    api -X PUT "repos/$REPO_SLUG/rulesets/$id" --input - <<<"$body" >/dev/null
    log_info "ruleset $name: updated"
  else
    api -X POST "repos/$REPO_SLUG/rulesets" --input - <<<"$body" >/dev/null
    log_info "ruleset $name: created"
  fi
}

ensure_labels() {
  gh label create demo-reset --repo "$REPO_SLUG" --force --color 5319e7 \
    --description "Demo rehearsal reset (scripts only)" >/dev/null
  gh label create policy-negative-test --repo "$REPO_SLUG" --force --color d93f0b \
    --description "Deliberately policy-violating PR for the negative test" >/dev/null
  log_info "labels demo-reset and policy-negative-test: present"
}

apply_standing() { # CODE_OWNER
  local inc rules names
  mapfile -t names < <(branches_array)
  inc="$(refs_json "${names[@]}")"
  put_ruleset "$RULESET_INTEGRITY" "$(ruleset_body "$RULESET_INTEGRITY" "$inc" '[]' \
    '[{"type":"deletion"},{"type":"non_fast_forward"}]')"
  rules="[$(pull_request_rule "$1")]"
  put_ruleset "$RULESET_TRACKED" "$(ruleset_body "$RULESET_TRACKED" "$inc" "$admin_bypass" "$rules")"
  put_ruleset "$RULESET_PROMOTE" "$(ruleset_body "$RULESET_PROMOTE" '["refs/heads/promote/*"]' "$admin_bypass" \
    '[{"type":"creation"},{"type":"update"}]')"
  ensure_labels
}

apply_spike() { # BRANCH
  local b="$1" listed
  [[ "$b" == rehearse/* ]] || die "the spike ruleset only targets rehearse/* branches, not '$b'"
  while IFS= read -r listed; do
    [[ "$listed" != "$b" ]] || die "'$b' is in RULESET_BRANCHES; the spike branch must not be"
  done < <(branches_array)
  local rules
  rules="$(jq -n -c --argjson pr "$(pull_request_rule true)" --arg ctx "$POLICY_CHECK_CONTEXT" \
    --argjson iid "$POLICY_CHECK_INTEGRATION_ID" \
    '[$pr, {type:"required_status_checks", parameters:{
        strict_required_status_checks_policy:false,
        required_status_checks:[{context:$ctx, integration_id:$iid}]}}]')"
  put_ruleset "$SPIKE_NAME" "$(ruleset_body "$SPIKE_NAME" "$(refs_json "$b")" "$admin_bypass" "$rules")"
}

remove_spike() {
  local id
  id="$(ruleset_id "$SPIKE_NAME")"
  if [[ -z "$id" ]]; then log_info "ruleset $SPIKE_NAME: not present"; return 0; fi
  api -X DELETE "repos/$REPO_SLUG/rulesets/$id" >/dev/null
  log_info "ruleset $SPIKE_NAME: deleted"
}

show() {
  local id
  {
    for id in $(api "repos/$REPO_SLUG/rulesets" | jq -r '.[].id'); do
      api "repos/$REPO_SLUG/rulesets/$id"
    done
  } | jq -s 'map({name, enforcement,
        include:.conditions.ref_name.include, exclude:.conditions.ref_name.exclude,
        bypass_actors:(.bypass_actors // []|map({actor_type,actor_id,bypass_mode})),
        rules:(.rules|map({type, parameters:(.parameters // null)}))}) | sort_by(.name)'
}

live_code_owner() { # is code-owner review currently on in the tracked ruleset?
  show | jq -r --arg n "$RULESET_TRACKED" \
    '[.[]|select(.name==$n)|.rules[]|select(.type=="pull_request")|.parameters.require_code_owner_review][0] // false'
}

# verify_integrity state lives in globals so the EXIT trap can still see it after the function returns.
VI_TMP="" VI_SCRATCH="" VI_CO="" VI_SAVED=""

verify_cleanup() {
  [[ -n "$VI_SCRATCH" ]] || return 0
  BRANCHES="$VI_SAVED"
  log_info "cleanup: unlisting $VI_SCRATCH and re-applying"
  apply_standing "$VI_CO" || log_error "re-apply failed: run 'apply' by hand, then delete $VI_SCRATCH"
  git -C "$VI_TMP/c" push -q origin --delete "$VI_SCRATCH" 2>/dev/null \
    || log_warn "could not delete $VI_SCRATCH; delete it by hand"
  rm -rf "$VI_TMP"
  VI_SCRATCH=""
}

verify_integrity() {
  local out rc=0 parent origin ident=(-c user.name=rehearsal -c user.email=rehearsal@example.invalid -c commit.gpgsign=false)
  VI_SCRATCH="rehearse/integrity-$(date +%s)"; VI_TMP="$(mktemp -d)"; VI_SAVED="$BRANCHES"
  VI_CO="$(live_code_owner)"
  origin="$(git -C "$COMMON_ROOT" remote get-url origin)"
  trap verify_cleanup EXIT
  git clone -q --depth 3 --branch "$TRACKED_BRANCH" "$origin" "$VI_TMP/c"
  BRANCHES="$VI_SAVED,$VI_SCRATCH"
  apply_standing "$VI_CO"
  git -C "$VI_TMP/c" "${ident[@]}" checkout -q -b "$VI_SCRATCH"
  parent="$(git -C "$VI_TMP/c" rev-parse HEAD)"
  git -C "$VI_TMP/c" "${ident[@]}" commit -q --allow-empty -m "rehearsal: integrity probe"
  git -C "$VI_TMP/c" push -q origin "$VI_SCRATCH" 2>/dev/null || die "could not push the scratch branch"
  log_info "scratch branch pushed; trying to force-push its parent over it"
  if out="$(git -C "$VI_TMP/c" push --force origin "$parent:refs/heads/$VI_SCRATCH" 2>&1)"; then
    log_error "FAIL: the force-push was accepted"; rc=1
  elif grep -qiE 'rule violation|non-fast-forward|protected ref' <<<"$out"; then
    log_info "ok: force-push refused: $(grep -iE 'violation|fast-forward|protected' <<<"$out" | head -1 | cut -c1-120)"
  else
    log_error "FAIL: push failed, but not for a ruleset reason: $out"; rc=1
  fi
  return "$rc"
}

main() {
  load_env
  command -v gh >/dev/null || die "gh not found"
  BRANCHES="${RULESET_BRANCHES:?RULESET_BRANCHES missing in demo.env}"
  : "${REPO_SLUG:?}" "${RULESET_INTEGRITY:?}" "${RULESET_TRACKED:?}" "${RULESET_PROMOTE:?}"
  case "${1:-}" in
    apply)
      case "${2:-}" in
        "")             apply_standing true ;;
        --minimal)      apply_standing false ;;
        --spike)        apply_spike "${3:?--spike needs a BRANCH}" ;;
        --spike-remove) remove_spike ;;
        *) usage ;;
      esac ;;
    show)             show ;;
    verify-integrity) verify_integrity ;;
    *) usage ;;
  esac
}
main "$@"
