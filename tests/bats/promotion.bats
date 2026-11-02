#!/usr/bin/env bats
# Tests for scripts/promotion-pr.sh: ensure, verify, merge, record-approval, demote.
# gh is a stateful stub, GitHub is a local bare repo, the operator clone is real. No network.

load helpers
load ops_helpers
load promotion_helpers

TEAM="@argo-multiverse-labs/promotion-board"
URL1="https://github.com/argo-multiverse-labs/argoconna26/pull/1#pullrequestreview-555"

setup() {
  make_promotion_fixture
}

# approve PR : a stubbed approving review, by a login that must never reach Git
approve() {
  printf '[{"state":"APPROVED","html_url":"https://github.com/argo-multiverse-labs/argoconna26/pull/%s#pullrequestreview-555","user":{"login":"stub-reviewer"}}]\n' "$1" \
    > "$PROMO_STATE/reviews-$1.json"
}

# ---------------------------------------------------------------- ensure

@test "ensure opens a fresh branch and PR with a non-empty diff" {
  before="$(origin_tip)"
  run promo ensure propose
  [ "$status" -eq 0 ]
  [ "$(open_pr_count)" -eq 1 ]
  b="$(branch_of 1)"
  [[ "$b" =~ ^promote/propose-[0-9]{14}-[a-z0-9]{4}$ ]]
  [ "$("$REAL_GIT" --git-dir="$ORIGIN" diff --name-only "refs/heads/build/demo...refs/heads/$b")" = "aiops/autonomy.yaml" ]
  # the tracked branch itself is untouched, and so is the operator clone
  [ "$(origin_tip)" = "$before" ]
  [ "$("$REAL_GIT" -C "$OP" rev-parse --abbrev-ref HEAD)" = "build/demo" ]
  [ -z "$("$REAL_GIT" -C "$OP" status --porcelain)" ]
  [ "$(autonomy_at "refs/heads/$b" .level)" = "propose" ]
  [ "$(autonomy_at "refs/heads/$b" .promotion.from_level)" = "suggest" ]
  [ "$(autonomy_at "refs/heads/$b" .promotion.dry_run_score)" = "pending" ]
  [ "$(autonomy_at "refs/heads/$b" .promotion.approver_required)" = "$TEAM" ]
  [ "$(autonomy_at "refs/heads/$b" .promotion.approved_by)" = "null" ]
  # only level, since and promotion changed
  [ "$(autonomy_at "refs/heads/$b" .touchpoints.propose)" = "1" ]
  # the PR number and pushed head are recorded for verify
  grep -qx 'pr=1' "$FIXTURE/.operator/promotion-propose"
  grep -qx "head=$("$REAL_GIT" --git-dir="$ORIGIN" rev-parse "refs/heads/$b")" "$FIXTURE/.operator/promotion-propose"
}

@test "ensure after a MERGED promotion PR opens a fresh PR with a non-empty diff" {
  promo ensure propose
  approve 1
  promo merge 1
  promo record-approval 1
  run promo demote
  [ "$status" -eq 0 ]
  [ "$(tip_autonomy .level)" = "suggest" ]
  run promo ensure propose
  [ "$status" -eq 0 ]
  [ "$(pr_state 1)" = "MERGED" ]
  [ "$(pr_state 2)" = "OPEN" ]
  [ "$(branch_of 2)" != "$(branch_of 1)" ]
  [ "$("$REAL_GIT" --git-dir="$ORIGIN" diff --name-only "refs/heads/build/demo...refs/heads/$(branch_of 2)")" = "aiops/autonomy.yaml" ]
  # a merged PR is not "closed as superseded"
  [ ! -f "$PROMO_STATE/comments-1" ]
}

@test "ensure closes a stale open promotion PR first" {
  promo ensure propose
  run promo ensure propose
  [ "$status" -eq 0 ]
  [ "$(pr_state 1)" = "CLOSED" ]
  [ "$(pr_state 2)" = "OPEN" ]
  [ "$(open_pr_count)" -eq 1 ]
  grep -qx "superseded by a fresh promotion PR" "$PROMO_STATE/comments-1"
  # the close comes before the create
  [ "$(gh_calls | grep -n 'pr close 1' | head -1 | cut -d: -f1)" -lt "$(gh_calls | grep -n 'pr create' | tail -1 | cut -d: -f1)" ]
}

@test "ensure refuses to skip a level" {
  run promo ensure act
  [ "$status" -ne 0 ]
  [[ "$output" == *"propose"* ]]
  ! gh_calls | grep -q 'pr create'
  [ -z "$("$REAL_GIT" --git-dir="$ORIGIN" for-each-ref refs/heads/promote)" ]
  [ "$(open_pr_count)" -eq 0 ]
}

@test "ensure refuses to promote to suggest or to an unknown level" {
  run promo ensure suggest
  [ "$status" -ne 0 ]
  run promo ensure bogus
  [ "$status" -ne 0 ]
  ! gh_calls | grep -q 'pr create'
}

@test "ensure uses a unique branch name when called twice in the same second" {
  export PROMOTION_STAMP=20261103120000
  promo ensure propose
  promo ensure propose
  [ "$(branch_of 1)" != "$(branch_of 2)" ]
  [[ "$(branch_of 1)" == promote/propose-20261103120000-* ]]
  [[ "$(branch_of 2)" == promote/propose-20261103120000-* ]]
  [ "$("$REAL_GIT" --git-dir="$ORIGIN" for-each-ref refs/heads/promote | wc -l)" -eq 2 ]
}

@test "ensure runs from the operator credential: gh gets no token override and the repo is explicit" {
  run promo ensure propose
  [ "$status" -eq 0 ]
  gh_calls | grep 'pr create' | grep -q -- '--repo argo-multiverse-labs/argoconna26'
  gh_calls | grep 'pr create' | grep -q -- '--base build/demo'
}

# ------------------------------------------------------------ record-approval

@test "record-approval writes the promotion-board role and review link, never a login" {
  promo ensure propose
  approve 1
  promo merge 1
  run promo record-approval 1
  [ "$status" -eq 0 ]
  [ "$(tip_autonomy .promotion.approved_by)" = "promotion-board member (review $URL1)" ]
  [ "$(tip_autonomy .promotion.pr)" = "1" ]
  [ "$(tip_autonomy .level)" = "propose" ]
  # it is a record, not a raise: one direct commit on top of the merge
  [ "$(origin_log | head -1)" = "chore(autonomy): record approval for promotion PR 1" ]
}

@test "record-approval writes admin-bypass when no approving review" {
  promo ensure propose
  promo merge 1 --admin
  run promo record-approval 1
  [ "$status" -eq 0 ]
  [ "$(tip_autonomy .promotion.approved_by)" = "admin-bypass" ]
}

@test "record-approval refuses a PR that is not merged" {
  promo ensure propose
  run promo record-approval 1
  [ "$status" -ne 0 ]
  [ "$(tip_autonomy .promotion)" = "null" ]
}

@test "record-approval refuses a PR the script did not open" {
  promo ensure propose
  promo merge 1 --admin
  run promo record-approval 7
  [ "$status" -ne 0 ]
}

@test "record-approval twice records once" {
  promo ensure propose
  promo merge 1 --admin
  promo record-approval 1
  tip="$(origin_tip)"
  run promo record-approval 1
  [ "$status" -eq 0 ]
  [ "$(origin_tip)" = "$tip" ]
}

@test "record-approval under STAGE=1 prints one line within STAGE_COLS" {
  promo ensure propose
  approve 1
  promo merge 1
  STAGE=1 STAGE_STRICT=1 run promo record-approval 1
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "recorded: board approval" ]
  [ "${#output}" -le 30 ]
}

@test "record-approval under STAGE=1 says admin bypass in one line" {
  promo ensure propose
  promo merge 1 --admin
  STAGE=1 STAGE_STRICT=1 run promo record-approval 1
  [ "$status" -eq 0 ]
  [ "$output" = "recorded: admin bypass" ]
}

@test "no login appears in the committed autonomy.yaml" {
  promo ensure propose
  approve 1
  promo merge 1
  promo record-approval 1
  promo demote
  promo ensure propose
  for ref in refs/heads/build/demo "refs/heads/$(branch_of 2)"; do
    ! "$REAL_GIT" --git-dir="$ORIGIN" show "$ref:aiops/autonomy.yaml" | grep -E 'stub-reviewer|stub-author'
  done
  ! "$REAL_GIT" --git-dir="$ORIGIN" log -p --all | grep -E 'stub-reviewer|stub-author'
}

# ---------------------------------------------------------------- merge, verify

@test "merge --admin is logged as admin-bypass" {
  promo ensure propose
  run promo merge 1 --admin
  [ "$status" -eq 0 ]
  [[ "$output" == *"admin-bypass"* ]]
  gh_calls | grep 'pr merge 1' | grep -q -- '--admin'
  [ "$(pr_state 1)" = "MERGED" ]
}

@test "merge merges when head and diff match" {
  promo ensure propose
  approve 1
  run promo merge 1
  [ "$status" -eq 0 ]
  gh_calls | grep 'pr merge 1' | grep -q -- '--merge'
  ! gh_calls | grep 'pr merge 1' | grep -q -- '--admin'
  gh_calls | grep 'pr merge 1' | grep -q -- "--match-head-commit $(jq -r .headRefOid "$PROMO_STATE/pr/1.json")"
  [ "$(tip_autonomy .level)" = "propose" ]
}

@test "merge without --admin refuses when there is no approving review" {
  promo ensure propose
  run promo merge 1
  [ "$status" -ne 0 ]
  ! gh_calls | grep -q 'pr merge'
  [ "$(pr_state 1)" = "OPEN" ]
}

@test "merge refuses when the PR head moved after ensure" {
  promo ensure propose
  printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' > "$PROMO_STATE/head-override-1"
  run promo merge 1 --admin
  [ "$status" -eq 8 ]
  [[ "$output" == *"head"* ]]
  ! gh_calls | grep -q 'pr merge'
}

@test "merge refuses when the diff touches more than aiops/autonomy.yaml" {
  promo ensure propose
  printf 'aiops/autonomy.yaml\napps/checkout/config/checkout-config.yaml\n' > "$PROMO_STATE/diff-override-1"
  run promo merge 1 --admin
  [ "$status" -eq 8 ]
  [[ "$output" == *"checkout-config.yaml"* ]]
  ! gh_calls | grep -q 'pr merge'
}

@test "merge refuses a PR with no recorded head" {
  run promo merge 3 --admin
  [ "$status" -eq 8 ]
  ! gh_calls | grep -q 'pr merge'
}

@test "verify under STAGE=1 prints one line" {
  promo ensure propose
  STAGE=1 STAGE_STRICT=1 run promo verify 1
  [ "$status" -eq 0 ]
  [ "$output" = "promotion PR: clean" ]
}

@test "verify under STAGE=1 refuses in one short line" {
  promo ensure propose
  printf 'x.txt\n' > "$PROMO_STATE/diff-override-1"
  STAGE=1 STAGE_STRICT=1 run promo verify 1
  [ "$status" -eq 8 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${#output}" -le 30 ]
}

# ---------------------------------------------------------------------- demote

@test "demote is a forward commit that lowers level" {
  promo ensure propose
  promo merge 1 --admin
  promo record-approval 1
  before="$(origin_tip)"
  PROMOTION_STAMP=20261110120000 run promo demote
  [ "$status" -eq 0 ]
  [ "$(tip_autonomy .level)" = "suggest" ]
  [ "$(tip_autonomy .promotion)" = "null" ]
  [ "$(tip_autonomy .since)" = "2026-11-10" ]
  "$REAL_GIT" --git-dir="$ORIGIN" merge-base --is-ancestor "$before" "$(origin_tip)"
  [ "$("$REAL_GIT" --git-dir="$ORIGIN" rev-list --count "$before..$(origin_tip)")" -eq 1 ]
  [[ "$(origin_log | head -1)" != Revert* ]]
  ! grep -qi 'revert' "$CALLS"
}

@test "demote steps down one level at a time" {
  seed_autonomy act
  promo demote
  [ "$(tip_autonomy .level)" = "propose" ]
  promo demote
  [ "$(tip_autonomy .level)" = "suggest" ]
}

@test "demote refuses when level already suggest" {
  before="$(origin_tip)"
  run promo demote
  [ "$status" -ne 0 ]
  [ "$(origin_tip)" = "$before" ]
}

@test "demote under STAGE=1 prints one line" {
  seed_autonomy propose
  STAGE=1 STAGE_STRICT=1 run promo demote
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${#output}" -le 30 ]
}

# ------------------------------------------------------------------ PR body

body() { cat "$PROMO_STATE/body-$1"; }

@test "promotion body contains score, time-at-level, approver_required" {
  mkdir -p "$FIXTURE/.dryruns"
  printf '{"n":20,"root_cause_matched":20}\n' > "$FIXTURE/.dryruns/summary.json"
  run promo ensure propose
  [ "$status" -eq 0 ]
  body 1 | grep -q 'Score 20/20 meets our 20/20 bar\.'
  body 1 | grep -Eq 'Time at `suggest`:\*\* [0-9]+ days? \(since 2026-11-02\)'
  body 1 | grep -q "compressed for the demo"
  body 1 | grep -q "$TEAM"
  ! body 1 | grep -q '\${'
  [ "$(autonomy_at "refs/heads/$(branch_of 1)" .promotion.dry_run_score)" = "20/20" ]
}

@test "promotion body states a below-bar score plainly" {
  mkdir -p "$FIXTURE/.dryruns"
  printf '{"n":20,"root_cause_matched":17}\n' > "$FIXTURE/.dryruns/summary.json"
  run promo ensure propose
  [ "$status" -eq 0 ]
  body 1 | grep -qF 'Score 17/20 is below our 20/20 bar.'
  # and the script warns for the gate report (D15)
  [[ "$output" == *"17/20"* ]]
  [[ "$output" == *"below"* ]]
}

@test "promotion body says plainly when there is no score yet" {
  run promo ensure propose
  [ "$status" -eq 0 ]
  body 1 | grep -qF 'No score yet'
  body 1 | grep -qF '20/20 bar'
  [[ "$output" == *"below"* ]]
}

@test "promotion body comes only from the committed template" {
  export PROMOTION_BODY="free text that must not appear"
  export BODY="free text that must not appear"
  run promo ensure propose
  [ "$status" -eq 0 ]
  ! body 1 | grep -q "free text"
  # no way to pass text in
  run promo ensure propose "free text that must not appear"
  [ "$status" -ne 0 ]
  run promo ensure propose --body "free text that must not appear"
  [ "$status" -ne 0 ]
  # the template is the first thing in the body
  [ "$(body 1 | head -1)" = '## Raise the agent from `suggest` to `propose`' ]
  [ "$(head -1 "$REPO_ROOT/scripts/templates/promotion-pr-body.md")" = '## Raise the agent from `${FROM_LEVEL}` to `${TO_LEVEL}`' ]
  # every variable the template uses is one the script substitutes
  for v in $(grep -o '\${[A-Z_]*}' "$REPO_ROOT/scripts/templates/promotion-pr-body.md" | sort -u); do
    grep -qF "$v" "$REPO_ROOT/scripts/promotion-pr.sh"
  done
}

@test "promotion body time at level and weeks follow the from-level" {
  seed_autonomy propose
  mkdir -p "$FIXTURE/.dryruns"
  printf '{"n":20,"root_cause_matched":20}\n' > "$FIXTURE/.dryruns/summary.json"
  run promo ensure act
  [ "$status" -eq 0 ]
  body 1 | grep -q 'Time at `propose`'
  body 1 | grep -q 'at least 4 weeks'
}

# ------------------------------------------------------------------ CODEOWNERS

@test "CODEOWNERS names the promotion board for the three paths and has no catch-all" {
  f="$REPO_ROOT/.github/CODEOWNERS"
  grep -Eq '^/aiops/autonomy\.yaml +@argo-multiverse-labs/promotion-board$' "$f"
  grep -Eq '^/policy/ +@argo-multiverse-labs/promotion-board$' "$f"
  grep -Eq '^/\.github/ +@argo-multiverse-labs/promotion-board$' "$f"
  ! grep -Eq '^\*' "$f"
  # the owner is the team from demo.env, not a person
  . "$REPO_ROOT/demo.env"
  [ "$PROMOTION_TEAM" = "@argo-multiverse-labs/promotion-board" ]
  [ "$(grep -v '^#' "$f" | grep -c '@')" -eq 3 ]
  [ "$(grep -v '^#' "$f" | grep -o '@[^ ]*' | sort -u)" = "$PROMOTION_TEAM" ]
}
