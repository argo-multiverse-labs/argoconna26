#!/usr/bin/env bash
# Move the branch Argo CD tracks (Task 6.8, D13).
#
#   scripts/retarget.sh BRANCH          (or: make retarget BRANCH=main)
#
# A move, never a rewind: BRANCH must already contain the current tracked tip. Runs under the
# cluster lock and stops at the first failure. Re-running after a failure resumes: the commit
# is skipped when origin/BRANCH already carries it, and every later step is idempotent.
#
#   1  refuse unless BRANCH contains origin/<tracked>, and the main checkout and the operator
#      clone are clean; and, because Argo CD and the bridge follow BRANCH before step 5
#      re-applies the rulesets, unless BRANCH is already protected by the live rulesets
#      (deletion, force-push, pull_request, the required check, and code-owner review while
#      that is live), its autonomy level is not above the tracked branch's, and it carries no
#      change to a code-owned path (CODEOWNERS on the tracked branch) the tracked branch lacks
#   2  one forward commit on BRANCH (operator clone, pushed): every targetRevision under gitops/
#      (root.yaml included), TRACKED_BRANCH in demo.env, BRANCH in RULESET_BRANCHES and the
#      bridge Deployment's TRACKED_BRANCH. The main checkout then switches to BRANCH, so the
#      Makefile and the scripts read the same demo.env.
#   3  kubectl apply -f gitops/root.yaml (the root Application was applied out of band by
#      gitops-bootstrap and would keep reading the old branch), then wait until the root and
#      every child Application report targetRevision == BRANCH, sync revision == BRANCH's tip,
#      Synced and Healthy
#   4  the bridge: its Deployment carries TRACKED_BRANCH (step 2), so wait for the rollout.
#      The plan named the Secret bridge-env here, but a Deployment `env` entry beats envFrom
#      and preflight fails while bridge-env exists, so the setting travels in git instead.
#   5  github-ruleset.sh apply, then read back deletion, non_fast_forward, pull_request, the
#      required policy-check (and code-owner review in full mode) on every RULESET_BRANCHES entry
#   6  .github/CODEOWNERS on BRANCH; any open promotion PR is closed and promotion-pr.sh ensure
#      opens a fresh one against the new base
#
# Overrides: RETARGET_WAIT_S (per Application, default 300), RETARGET_RULESET_MODE (unset =
# live: whatever the live tracked ruleset has, read with `github-ruleset.sh live-mode`; full
# turns code-owner review on; minimal is refused while code-owner review is live),
# RETARGET_GITHUB_PREFLIGHT=1 (also run `preflight.sh 2`, whose github sections are still to
# come with L5b), RETARGET_RULESET_SCRIPT and RETARGET_PROMOTION_SCRIPT (tests).
# Exit codes: 1 generic, 3 wrong context, 4 wait timed out, 5 cluster lock held.
#
# Why everything sits in functions and ends with `exit`: step 2 switches the main checkout,
# which can replace this very file while bash is still reading it.
# shellcheck disable=SC2329  # app_on_branch and friends are called through wait_for
set -euo pipefail
# shellcheck source=scripts/git-ops.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-ops.sh"

usage() { die "usage: retarget.sh BRANCH   (make retarget BRANCH=<branch>)"; }

# ------------------------------------------------------------ 1. refuse
validate_branch() {
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] || die "retarget: '$1' is not a plain branch name"
  git check-ref-format --branch "$1" >/dev/null 2>&1 || die "retarget: '$1' is not a valid branch name"
}

require_clean_trees() {
  [[ -z "$(git -C "$(main_root)" status --porcelain)" ]] \
    || die "retarget: the main checkout is not clean; commit or stash first"
  [[ -z "$(_og status --porcelain)" ]] \
    || die "retarget: the operator clone $OPERATOR_DIR is not clean"
}

# fetch_branch BRANCH : origin's BRANCH into the operator clone's remote-tracking ref.
fetch_branch() {
  _ogq fetch --quiet origin "refs/heads/$1:refs/remotes/origin/$1" \
    || die "retarget: branch '$1' is not on origin (or origin/$1 cannot fast-forward)"
}

require_move_forward() { # OLD NEW
  fetch_branch "$1"
  fetch_branch "$2"
  _og merge-base --is-ancestor "refs/remotes/origin/$1" "refs/remotes/origin/$2" \
    || die "retarget: origin/$2 does not contain origin/$1 (the tracked tip); a retarget is a move, never a rewind. Fast-forward $2 first."
}

# --------------------------------- 1b. the destination is safe to follow (before any change)
# Argo CD and the bridge follow NEW from step 3 on, and the rulesets are only re-applied at
# step 5, so NEW must already be protected, must not raise the autonomy level, and must not
# carry code-owned changes (autonomy, policy, workflows) that no board review saw on OLD.

# ruleset_mode : minimal | full, from RETARGET_RULESET_MODE, else the live tracked ruleset
# (github-ruleset.sh live-mode). Explicit minimal is refused while code-owner review is live.
LIVE_CO=false
ruleset_mode() {
  local script="${RETARGET_RULESET_SCRIPT:-$GIT_OPS_DIR/github-ruleset.sh}" live
  live="$("$script" live-mode)" || die "retarget: cannot read the live ruleset mode (github-ruleset.sh live-mode)"
  case "$live" in
    full | policy-check) LIVE_CO=true ;;
    minimal | minimal-policy-check) LIVE_CO=false ;;
    *) die "retarget: unknown live ruleset mode '$live'" ;;
  esac
  case "${RETARGET_RULESET_MODE:-live}" in
    live) if [[ "$LIVE_CO" == true ]]; then RULESET_MODE=full; else RULESET_MODE=minimal; fi ;;
    full) RULESET_MODE=full ;;
    minimal)
      [[ "$LIVE_CO" == false ]] \
        || die "retarget: RETARGET_RULESET_MODE=minimal would turn off the live code-owner review; leave it unset (live mode) or use full"
      RULESET_MODE=minimal ;;
    *) die "retarget: RETARGET_RULESET_MODE must be live, minimal or full, not '${RETARGET_RULESET_MODE}'" ;;
  esac
  log_info "ruleset mode: $RULESET_MODE (live: $live)"
}

require_protected() { # NEW
  rules_ok "$1" "$LIVE_CO" \
    || die "retarget: $1 is not protected yet (deletion, non_fast_forward, pull_request, the required $POLICY_CHECK_CONTEXT$([[ "$LIVE_CO" == true ]] && echo ', code-owner review')). Add it to RULESET_BRANCHES on the tracked branch, run github-ruleset.sh apply, then retry."
  log_info "$1 is already protected by the live rulesets"
}

level_rank() { case "$1" in propose) echo 1 ;; act) echo 2 ;; *) echo 0 ;; esac; }

# branch_level BRANCH : the level in AUTONOMY_FILE on origin/BRANCH; anything missing,
# unreadable or invalid counts as suggest (Global Constraints).
branch_level() {
  local l
  l="$(_og show "refs/remotes/origin/$1:$AUTONOMY_FILE" 2>/dev/null | yq -r '.level // ""' 2>/dev/null || true)"
  case "$l" in suggest | propose | act) echo "$l" ;; *) echo suggest ;; esac
}

require_no_autonomy_raise() { # OLD NEW
  local lo ln
  lo="$(branch_level "$1")" ln="$(branch_level "$2")"
  (($(level_rank "$ln") <= $(level_rank "$lo"))) \
    || die "retarget: autonomy on $2 is $ln, above $lo on $1; a retarget never raises the level (promote on $1 through its promotion PR first)"
}

# codeowned PATH PATTERN... : true when PATH matches a CODEOWNERS pattern (/dir/ prefix, exact
# path, or *).
codeowned() {
  local path="$1" pat
  shift
  for pat in "$@"; do
    pat="${pat#/}"
    case "$pat" in
      '*' | '') return 0 ;;
      */) [[ "$path" == "$pat"* ]] && return 0 ;;
      *) [[ "$path" == "$pat" || "$path" == "$pat/"* ]] && return 0 ;;
    esac
  done
  return 1
}

require_no_codeowned_changes() { # OLD NEW
  local f
  local -a pats=() hits=()
  mapfile -t pats < <(_og show "refs/remotes/origin/$1:.github/CODEOWNERS" 2>/dev/null \
    | sed -e 's/#.*//' | awk 'NF {print $1}')
  ((${#pats[@]} > 0)) || die "retarget: no .github/CODEOWNERS on $1 to check the move against"
  while IFS= read -r f; do
    [[ -n "$f" ]] && codeowned "$f" "${pats[@]}" && hits+=("$f")
  done < <(_og diff --name-only "refs/remotes/origin/$1" "refs/remotes/origin/$2")
  ((${#hits[@]} == 0)) \
    || die "retarget: $2 changes code-owned paths that $1 lacks (${hits[*]}); land them on $1 through a reviewed PR first"
}

# ------------------------------------------------ 2. the commit and the switch
# rewrite_target_revisions OLD NEW : in the operator clone, every targetRevision under gitops/
# that names OLD. Another value (a chart version) is left alone, with a warning.
rewrite_target_revisions() {
  local old="$1" new="$2" f tmp
  while IFS= read -r -d '' f; do
    tmp="$(mktemp)"
    awk -v old="$old" -v new="$new" '
      match($0, /^[[:space:]]*targetRevision:[[:space:]]*/) {
        pre = substr($0, 1, RLENGTH); val = substr($0, RLENGTH + 1)
        sub(/[[:space:]]+$/, "", val); gsub(/["\047]/, "", val)
        if (val == old) { print pre new; next }
      }
      { print }' "$f" >"$tmp"
    cat "$tmp" >"$f"
    rm -f "$tmp"
  done < <(find "$OPERATOR_DIR/gitops" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)
  if grep -rEn "^[[:space:]]*targetRevision:[[:space:]]*[\"']?${old//./\\.}[\"']?[[:space:]]*$" "$OPERATOR_DIR/gitops" >/dev/null 2>&1; then
    die "retarget: a targetRevision under gitops/ still names $old"
  fi
}

# rewrite_demo_env NEW : TRACKED_BRANCH, and NEW in RULESET_BRANCHES.
rewrite_demo_env() {
  local new="$1" file="$OPERATOR_DIR/demo.env" tmp
  [[ -w "$file" ]] || die "retarget: cannot write $file"
  grep -q "^TRACKED_BRANCH=" "$file" || die "retarget: demo.env has no TRACKED_BRANCH line"
  grep -q "^RULESET_BRANCHES=" "$file" || die "retarget: demo.env has no RULESET_BRANCHES line"
  tmp="$(mktemp)"
  awk -v new="$new" '
    /^TRACKED_BRANCH=/ { print "TRACKED_BRANCH=" new; next }
    /^RULESET_BRANCHES=/ {
      n = split(substr($0, 18), parts, ","); found = 0
      for (i = 1; i <= n; i++) if (parts[i] == new) found = 1
      print $0 (found ? "" : "," new); next
    }
    { print }' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# rewrite_bridge_deployment NEW : the TRACKED_BRANCH env entry, one-line or two-line form.
rewrite_bridge_deployment() {
  local new="$1" file="$OPERATOR_DIR/bridge/deploy/deployment.yaml" tmp
  [[ -f "$file" ]] || { log_warn "retarget: no bridge Deployment in the clone; skipping it"; return 0; }
  tmp="$(mktemp)"
  awk -v new="$new" '
    function swap(s,   i) {
      i = index(s, "value:"); if (!i) return s
      sub(/value:[[:space:]]*["\047]?[^"\047},[:space:]]+["\047]?/, "value: " new, s)
      return s
    }
    pending && /^[[:space:]]*value:/ { print swap($0); pending = 0; hit = 1; next }
    { pending = 0 }
    /name:[[:space:]]*TRACKED_BRANCH[[:space:]]*,/ && /value:/ { print swap($0); hit = 1; next }
    /name:[[:space:]]*TRACKED_BRANCH[[:space:]]*$/ { pending = 1 }
    { print }
    END { if (!hit) exit 3 }' "$file" >"$tmp" \
    || { rm -f "$tmp"; die "retarget: no TRACKED_BRANCH entry in the bridge Deployment"; }
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# op_checkout_branch BRANCH : the operator clone on BRANCH, equal to origin's tip.
op_checkout_branch() {
  fetch_branch "$1"
  _ogq checkout --quiet -B "$1" "refs/remotes/origin/$1"
}

# commit_retarget OLD NEW : one forward commit on NEW, pushed. Nothing to do when origin/NEW
# already carries it (an earlier run got this far).
commit_retarget() {
  local old="$1" new="$2" sha
  local -a files=()
  TRACKED_BRANCH="$new"
  op_checkout_branch "$new"
  op_sync
  rewrite_target_revisions "$old" "$new"
  rewrite_demo_env "$new"
  rewrite_bridge_deployment "$new"
  mapfile -t files < <(_og diff --name-only)
  if ((${#files[@]} == 0)); then
    log_info "origin/$new already tracks $new: no commit needed"
    return 0
  fi
  sha="$(op_commit_push "chore(demo): track $new" "${files[@]}")"
  log_info "pushed ${sha:0:9} to $new: ${files[*]}"
}

# switch_main_checkout BRANCH : the main checkout on BRANCH at origin's tip, so demo.env agrees.
switch_main_checkout() {
  local branch="$1" root
  root="$(main_root)"
  git -C "$root" fetch --quiet origin "refs/heads/$branch:refs/remotes/origin/$branch" \
    || die "retarget: cannot fetch $branch into the main checkout"
  if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$root" switch --quiet "$branch" || die "retarget: cannot switch the main checkout to $branch"
    git -C "$root" merge --ff-only --quiet "refs/remotes/origin/$branch" \
      || die "retarget: local $branch cannot fast-forward to origin/$branch"
  else
    git -C "$root" switch --quiet -c "$branch" --track "origin/$branch" \
      || die "retarget: cannot switch the main checkout to $branch"
  fi
  log_info "main checkout is on $branch"
}

# ------------------------------------------------------------- 3. Argo CD
branch_tip() { _og ls-remote origin "refs/heads/$1" | cut -f1; }

# app_on_branch APP BRANCH : targetRevision, sync revision, Synced and Healthy.
app_on_branch() {
  local app="$1" branch="$2" tip
  tip="$(branch_tip "$branch")"
  [[ -n "$tip" ]] || return 1
  k get application "$app" -n "$NS_ARGOCD" -o json | jq -e --arg b "$branch" --arg sha "$tip" '
    ((.spec.source // .spec.sources[0]).targetRevision) == $b
    and .status.sync.revision == $sha
    and .status.sync.status == "Synced"
    and .status.health.status == "Healthy"' >/dev/null
}

refresh_app() {
  k annotate application "$1" -n "$NS_ARGOCD" "argocd.argoproj.io/refresh=${ARGO_REFRESH:-normal}" --overwrite >/dev/null
}

reapply_root_and_wait() {
  local branch="$1" root app wait_s="${RETARGET_WAIT_S:-300}"
  local -a apps=()
  root="$(main_root)"
  (cd "$root" && k apply -f gitops/root.yaml) || die "retarget: kubectl apply -f gitops/root.yaml failed"
  mapfile -t apps < <(for f in "$root"/gitops/apps/*.yaml; do yq -r '.metadata.name' "$f"; done)
  ((${#apps[@]} > 0)) || die "retarget: no child Applications under gitops/apps"
  refresh_app root
  wait_for "root on $branch, synced and healthy" "$wait_s" app_on_branch root "$branch"
  for app in "${apps[@]}"; do refresh_app "$app"; done
  for app in "${apps[@]}"; do
    wait_for "$app on $branch, synced and healthy" "$wait_s" app_on_branch "$app" "$branch"
  done
}

# -------------------------------------------------------------- 4. the bridge
bridge_branch_is() {
  k get deployment bridge -n "$NS_AIOPS" -o json | jq -e --arg b "$1" '
    ([.spec.template.spec.containers[].env[]? | select(.name == "TRACKED_BRANCH") | .value] | first) == $b
    and .status.observedGeneration == .metadata.generation' >/dev/null
}

bridge_answers() {
  curl -sf --max-time 5 "127.0.0.1:${PORT_BRIDGE}/status" | jq -e '.test_hooks_active == false' >/dev/null
}

wait_for_bridge() {
  local branch="$1"
  wait_for "the bridge Deployment carries TRACKED_BRANCH=$branch" "${RETARGET_WAIT_S:-300}" bridge_branch_is "$branch"
  k rollout status deployment/bridge -n "$NS_AIOPS" --timeout=180s >/dev/null \
    || die "retarget: the bridge rollout did not finish"
  wait_for "bridge /status answers" 90 bridge_answers
}

# ---------------------------------------------------------------- 5. rulesets
apply_rulesets() {
  local script="${RETARGET_RULESET_SCRIPT:-$GIT_OPS_DIR/github-ruleset.sh}"
  case "$RULESET_MODE" in
    minimal) "$script" apply --minimal ;;
    full) "$script" apply ;;
    *) die "retarget: no ruleset mode" ;;
  esac
}

# rules_ok BRANCH WANT_CODE_OWNER : GitHub enforces deletion, non_fast_forward, pull_request and
# the required check on BRANCH (and code-owner review when WANT_CODE_OWNER is true).
rules_ok() {
  local rules
  rules="$(gh api "repos/${REPO_SLUG}/rules/branches/$1")" || die "retarget: cannot read the rules on $1"
  jq -e --arg c "$POLICY_CHECK_CONTEXT" --argjson i "$POLICY_CHECK_INTEGRATION_ID" --argjson co "$2" '
    ([.[].type] | (index("deletion") != null) and (index("non_fast_forward") != null) and (index("pull_request") != null))
    and any(.[]; .type == "required_status_checks"
                 and any(.parameters.required_status_checks[]?; .context == $c and .integration_id == $i))
    and (if $co then any(.[]; .type == "pull_request" and .parameters.require_code_owner_review == true)
         else true end)' <<<"$rules" >/dev/null
}

# verify_rules_on BRANCH : read back what GitHub enforces on BRANCH after the apply.
verify_rules_on() {
  local b="$1" co=false
  [[ "$RULESET_MODE" == full ]] && co=true
  rules_ok "$b" "$co" \
    || die "retarget: $b lacks deletion, non_fast_forward, pull_request or the required $POLICY_CHECK_CONTEXT (integration $POLICY_CHECK_INTEGRATION_ID)$([[ "$co" == true ]] && echo ' or code-owner review')"
  log_info "rules on $b: deletion, force-push, pull_request and $POLICY_CHECK_CONTEXT$([[ "$co" == true ]] && echo ', code-owner review')"
}

verify_all_rules() {
  local b
  local -a branches=()
  IFS=',' read -r -a branches <<<"$RULESET_BRANCHES"
  for b in "${branches[@]}"; do
    [[ -n "$b" ]] && verify_rules_on "$b"
  done
  if [[ "${RETARGET_GITHUB_PREFLIGHT:-0}" == 1 ]]; then
    "$GIT_OPS_DIR/preflight.sh" 2 || die "retarget: preflight 2 failed"
  else
    log_info "github-admin and github-runtime preflight sections: not run here (set RETARGET_GITHUB_PREFLIGHT=1 once L5b adds them)"
  fi
}

# ------------------------------------------------- 6. CODEOWNERS, promotion PRs
require_codeowners() {
  local name
  name="$(gh api "repos/${REPO_SLUG}/contents/.github/CODEOWNERS?ref=$1" | jq -r '.name // empty')" || true
  [[ "$name" == CODEOWNERS ]] || die "retarget: .github/CODEOWNERS not found on $1"
  log_info "CODEOWNERS present on $1"
}

# recreate_promotion_prs NEW : every open promotion PR whose base is not NEW is closed, and
# ensure opens a fresh one for the same target level against NEW.
recreate_promotion_prs() {
  local new="$1" script="${RETARGET_PROMOTION_SCRIPT:-$GIT_OPS_DIR/promotion-pr.sh}" prs n head level
  prs="$(gh pr list --repo "$REPO_SLUG" --state open --limit 100 --json number,headRefName,baseRefName)" \
    || die "retarget: cannot list open PRs"
  while IFS=$'\t' read -r n head; do
    [[ -n "$n" ]] || continue
    level="${head#promote/}"
    level="${level%%-*}"
    gh pr close "$n" --repo "$REPO_SLUG" --comment "retargeted to $new: a fresh promotion PR follows" >/dev/null \
      || die "retarget: could not close promotion PR $n"
    log_info "closed promotion PR $n (base moved)"
    "$script" ensure "$level" || die "retarget: could not open a fresh $level promotion PR against $new"
  done < <(jq -r --arg b "$new" '.[] | select(.headRefName | startswith("promote/")) | select(.baseRefName != $b)
                                  | [.number, .headRefName] | @tsv' <<<"$prs")
}

# ------------------------------------------------------------------- main
main() {
  (($# == 1)) || usage
  local new="$1" old
  validate_branch "$new"
  load_env
  require_context
  cluster_lock
  op_require_configured
  old="$TRACKED_BRANCH"

  if [[ "$new" == "$old" ]]; then
    log_info "already tracking $new: resuming at the root app"
    require_branch_main "$new"
    op_checkout_branch "$new"
    ruleset_mode
  else
    require_clean_trees
    require_move_forward "$old" "$new"
    ruleset_mode
    require_protected "$new"
    require_no_autonomy_raise "$old" "$new"
    require_no_codeowned_changes "$old" "$new"
    git -C "$(main_root)" fetch --quiet origin "refs/heads/$new:refs/remotes/origin/$new" \
      || die "retarget: cannot fetch $new into the main checkout"
    git -C "$(main_root)" merge-base --is-ancestor HEAD "refs/remotes/origin/$new" \
      || die "retarget: the main checkout has commits that are not on origin/$new; push or drop them first"
    commit_retarget "$old" "$new"
    switch_main_checkout "$new"
    load_env
    [[ "$TRACKED_BRANCH" == "$new" ]] || die "retarget: demo.env on $new says TRACKED_BRANCH=$TRACKED_BRANCH"
    require_context
  fi
  export TRACKED_BRANCH="$new"

  reapply_root_and_wait "$new"
  wait_for_bridge "$new"
  apply_rulesets
  verify_all_rules
  require_codeowners "$new"
  recreate_promotion_prs "$new"
  log_info "retargeted: Argo CD, the bridge and the rulesets now follow $new"
}

require_branch_main() {
  [[ "$(git -C "$(main_root)" rev-parse --abbrev-ref HEAD)" == "$1" ]] \
    || die "retarget: demo.env says $1 but the main checkout is on another branch"
}

main "$@"; exit $?
