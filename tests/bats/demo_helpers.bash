# Helpers for demo_rungs.bats: a throwaway checkout, stub binaries and a scripted GitHub/Argo
# world. The state lives in files under $ST, so a stub can change what the next call returns.
#
#   $ST/rev            the revision Argo reports as synced
#   $ST/bumped         a bump or rearm happened       $ST/fixed   make fix ran
#   $ST/merged         the fix PR was merged           $ST/degraded-seen   Argo reported Degraded
#   $ST/level          the tracked autonomy level      $ST/approved        approved_by, once recorded
#   $ST/comments.json  bot comments (shown only after Degraded was seen)
#   $ST/prs.json       agent PRs (the same)             $ST/pr-N.json  what `gh pr view N` reads
#   $ST/rejected       the bridge's rejected count      $ST/auto-merge-by   a login: GitHub merges a PR on first look

CAUSE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BUMP=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
MERGE=cccccccccccccccccccccccccccccccccccccccc
HEAD_SHA=dddddddddddddddddddddddddddddddddddddddd
REF=CHG-ABCDEF
BOT='argoconna26-agent[bot]'
SLUG=argo-multiverse-labs/argoconna26

write_stub() { # NAME : the body comes on stdin
  mkdir -p "$STUBS"
  { printf '#!/usr/bin/env bash\n'; cat; } >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

demo_setup() { # LEVEL : the tracked autonomy level the scenario starts at
  rm -rf "$BATS_TEST_TMPDIR/repo" "$BATS_TEST_TMPDIR/state" "$BATS_TEST_TMPDIR/stubs"
  unset DEMO_AUTOMERGE_FOR_TEST DEMO_REJECT_FOR_TEST VERIFY_RC
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$FIXTURE"
  mkdir -p "$FIXTURE/.kube" "$FIXTURE/.operator"
  ln -s "$REPO_ROOT/bridge" "$FIXTURE/bridge" # assert_fix_pr_body reads the bridge's templates
  ST="$BATS_TEST_TMPDIR/state"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  LOG="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$ST"
  : >"$LOG"
  echo "$1" >"$ST/level"
  echo "$BUMP" >"$ST/rev"
  echo 0 >"$ST/rejected"
  export ST STUBS LOG FIXTURE CAUSE BUMP MERGE HEAD_SHA REF BOT SLUG
  # shellcheck disable=SC1091
  . "$REPO_ROOT/demo.env"
  # The demo scripts size to the demo terminal (DEMO_COLS), not demo.env's 30; the assertions
  # (assert_fits, the full-width bars) check against the same width.
  export DEMO_COLS=72
  STAGE_COLS="$DEMO_COLS"

  write_stub kubectl <<'STUB'
case "$*" in
  *"config current-context"*) echo kind-argoconna26 ;;
  *annotate*) echo "kubectl annotate ${*: -2}" >>"$LOG" ;;
  *"get applications"*) echo '{"items":[]}' ;;
  *"{.status.sync.revision} {.status.sync.status}"*)
    if [[ -e "$ST/merged" ]]; then echo "$MERGE Synced Succeeded"; else echo "$(cat "$ST/rev") Synced Succeeded"; fi ;;
  *"{.status.sync.revision}"*) if [[ -e "$ST/merged" ]]; then echo "$MERGE"; else cat "$ST/rev"; fi ;;
  *"{.status.health.status}"*)
    if [[ -e "$ST/bumped" && ! -e "$ST/fixed" && ! -e "$ST/merged" ]]; then touch "$ST/degraded-seen"; echo Degraded; else echo Healthy; fi ;;
esac
STUB
  write_stub make <<'STUB'
echo "make $*" >>"$LOG"
OP="$FIXTURE/.operator"
case "$1" in
  bump) printf 'bump: %s\n' "$BUMP" >"$OP/last-bump"; touch "$ST/bumped"; echo "$BUMP" >"$ST/rev"; echo "pushed: image bump" ;;
  rearm) printf 'cause: %s\nbump: %s\nchange_ref: %s\n' "$CAUSE" "$BUMP" "$REF" >"$OP/last-rearm"
         touch "$ST/bumped"; echo "$BUMP" >"$ST/rev"; echo "pushed: rearm" ;;
  fix) touch "$ST/fixed"; echo "pushed: config 2000, cv 8" ;;
  demote) echo suggest >"$ST/level"; echo "demoted: propose -> suggest" ;;
  night)
    if ( flock -n 9 ) 9>>"$FIXTURE/.kube/cluster.lock"; then echo "night: lock free, held=${CLUSTER_LOCK_HELD:-none}" >>"$LOG"
    else echo "night: lock HELD" >>"$LOG"; fi
    printf 'RUN_TS=%s\nT_TYPED=%s\n' "$(date +%s)" "$(date +%s)" >"$OP/last-run"
    touch "$ST/bumped"; echo "$BUMP" >"$ST/rev"; echo "running the nightly job now" ;;
esac
STUB
  write_stub gh <<'STUB'
echo "gh $*" >>"$LOG"
args=("$@")
jq_expr=""
for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[i]}" == --jq ]] && jq_expr="${args[i + 1]}"; done
out() { if [[ -n "$jq_expr" ]]; then jq -r "$jq_expr"; else cat; fi; }
gated() { if [[ -e "$ST/degraded-seen" && -e "$ST/$1" ]]; then cat "$ST/$1"; else echo '[]'; fi; }
prfile() { # first number in the arguments after pr view|merge|close
  local a; for a in "${args[@]:2}"; do [[ "$a" =~ ^[0-9]+$ ]] && { echo "$ST/pr-$a.json"; return; }; done
}
set_pr() { local f; f="$(prfile)"; jq "$1" "$f" >"$f.new" && mv "$f.new" "$f"; }
case "$1 $2" in
  "auth token") echo tok ;;
  "pr view")
    f="$(prfile)"
    if [[ -e "$ST/auto-merge-by" && "$f" == "$ST/pr-7.json" && "$*" == *state* && "$(jq -r .state "$f")" == OPEN ]]; then
      set_pr ".state = \"MERGED\" | .mergeCommit = {oid: \"$MERGE\"} | .mergedBy = {login: \"$(cat "$ST/auto-merge-by")\"}"; touch "$ST/merged"
    fi
    out <"$f" ;;
  "pr merge") set_pr ".state = \"MERGED\" | .mergeCommit = {oid: \"$MERGE\"} | .mergedBy = {login: \"luke\"}"; touch "$ST/merged" ;;
  "pr close") set_pr '.state = "CLOSED"'; echo $(($(cat "$ST/rejected") + 1)) >"$ST/rejected" ;;
  "pr diff") echo aiops/autonomy.yaml ;;
  "api -H")
    if [[ "$*" == *contents/aiops/autonomy.yaml* ]]; then
      printf 'level: %s\npromotion:\n  approved_by: %s\n' "$(cat "$ST/level")" "$([[ -e "$ST/approved" ]] && cat "$ST/approved" || echo null)"
    fi ;;
  "api repos/"*)
    case "$2" in
      */commits/*/comments*) gated comments.json | out ;;
      */commits/*/pulls*) echo '[]' | out ;;
      */issues/*/comments*) echo '[]' | out ;;
      */pulls\?state=all*) gated prs.json | out ;;
      */pulls/*/files*) out <"$ST/files.json" ;;
      */check-runs*) out <"$ST/checkruns.json" ;;
    esac ;;
esac
exit 0
STUB
  write_stub curl <<'STUB'
case "$*" in
  *"/incidents"*)
    if [[ -e "$ST/fixed" || -e "$ST/merged" ]]; then r='"2999-01-01T00:01:00Z"'; else r=null; fi
    printf '[{"revision":"%s","detected_at":"2999-01-01T00:00:00Z","resolved_at":%s}]\n' "$BUMP" "$r" ;;
  *"/metrics"*) printf 'aiops_fix_prs_total{outcome="rejected"} %s.0\n' "$(cat "$ST/rejected")" ;;
esac
STUB
  write_stub journalctl <<'STUB'
printf 'rearm starting\ncause: %s\nbump: %s\nchange_ref: %s\n' "$CAUSE" "$BUMP" "$REF"
STUB
  write_stub open-tab <<'STUB'
echo "open $1" >>"$LOG"
STUB
  write_stub promotion-pr <<'STUB'
echo "promo $*" >>"$LOG"
case "$1" in
  verify) if ((${VERIFY_RC:-0} == 0)); then echo "promotion PR: clean"; else echo "refused: promotion PR changed"; exit "$VERIFY_RC"; fi ;;
  record-approval) if [[ "$2" == 13 ]]; then echo act >"$ST/level"; else echo propose >"$ST/level"; fi
                   echo admin-bypass >"$ST/approved"; echo "recorded: admin bypass" ;;
  merge) f="$ST/pr-$2.json"; jq '.state = "MERGED"' "$f" >"$f.new" && mv "$f.new" "$f" ;;
  ensure) # a fresh promotion PR: act is 13, propose 12
    n=12; [[ "$2" == act ]] && n=13
    jq -n --argjson n "$n" '{number: $n, state: "OPEN", url: ("https://github.com/x/y/pull/" + ($n | tostring))}' >"$ST/pr-$n.json"
    printf 'pr=%s\nhead=x\nbranch=promote-x\n' "$n" >"$FIXTURE/.operator/promotion-$2"
    echo "promotion PR open" ;;
esac
STUB
  write_stub overnight-verify <<'STUB'
echo "overnight-verify $*" >>"$LOG"
echo "PASS everything"
exit "${VERIFY_EXIT:-0}"
STUB

  export PATH="$STUBS:$PATH" TOOLS_BIN="$STUBS"
  export TYPE_SPEED= NO_WAIT=true STAGE_STRICT=1
  export DEMO_OPEN="$STUBS/open-tab" PROMOTION_PR_SH="$STUBS/promotion-pr" OVERNIGHT_VERIFY="$STUBS/overnight-verify"
  export DEGRADED_WAIT_S=6 OUTCOME_WAIT_S=6 HEALTHY_WAIT_S=6 PROMO_WAIT_S=6 FIX_PR_WAIT_S=6 POLICY_WAIT_S=6 MERGED_WAIT_S=6 SYNC_WAIT_S=6
  jq -n --arg a "$CONFIG_FILE" --arg b "$ROLLOUT_FILE" \
    '[{filename: $a, additions: 1, deletions: 1}, {filename: $b, additions: 1, deletions: 1}]' >"$ST/files.json"
  echo '{"check_runs":[{"app":{"id":15368},"started_at":"2999-01-01T00:00:00Z","conclusion":"success"}]}' >"$ST/checkruns.json"
}

# comment_json BODY : a bot comment on the cause, created far in the future (so after any T0).
set_comment() {
  jq -n --arg body "$1" --arg bot "$BOT" \
    '[{user: {login: $bot}, created_at: "2999-01-01T00:00:00Z", html_url: "https://github.com/x/y/commit/z#c1", body: $body}]' \
    >"$ST/comments.json"
}

rca_body() {
  printf '## Root cause\n\nThe upstream timeout dropped from 2000 to 200.\n\n- checkout-config: UPSTREAM_TIMEOUT_MS 2000 to 200\n- Timeline: %s merged PR-242\n\nCause: %s (PR-242 tune upstream timeout)\n\nA human should check it.\n' "$REF" "$CAUSE"
}

refusal_body() {
  printf '## Agent refused\n\nThe investigation finished, but its answer did not pass the guardrails.\n\n- low_confidence: confidence 0.4 is below 0.7\n\nA human should take this one. [Argo CD history](http://x) · autonomy: suggest\n'
}

handoff_body() { printf 'Investigation did not finish in 115 s; a human should take this one.\n'; }

# fix_body LEVEL : a fix PR body that passes assert_fix_pr_body for CAUSE and REF.
fix_body() {
  printf '## Root cause\n\nCause: %s (PR-242 tune upstream timeout)\n\nThe upstream timeout dropped.\n\n- checkout-config changed\n- Timeline: %s merged PR-242\n\n## Blast radius\n\nChanges the key. Leaves the rest unchanged.\n\n%s\n' \
    "$CAUSE" "$REF" "$(yq -r ".footer.$1" "$REPO_ROOT/bridge/src/bridge/templates/pr_sections.yaml")"
}

# set_prs : one open agent PR (7) with the given body, and the promotion PR (12), already merged.
set_prs() { # BODY
  jq -n --arg bot "$BOT" '[{number: 7, html_url: "https://github.com/x/y/pull/7", state: "open",
    created_at: "2999-01-01T00:00:00Z", head: {ref: "agent/checkout-aaaaaaa-bbbbbbb"}, user: {login: $bot}}]' >"$ST/prs.json"
  jq -n --arg body "$1" --arg head "$HEAD_SHA" \
    '{number: 7, state: "OPEN", url: "https://github.com/x/y/pull/7", headRefOid: $head, mergeCommit: null,
      mergedAt: null, mergedBy: null, body: $body}' >"$ST/pr-7.json"
  jq -n '{number: 12, state: "MERGED", url: "https://github.com/x/y/pull/12"}' >"$ST/pr-12.json"
  printf 'pr=12\nhead=%s\nbranch=promote/propose-x\n' "$HEAD_SHA" >"$FIXTURE/.operator/promotion-propose"
}

seed_rung1() { printf 'cause: %s\nchange_ref: %s\n' "$CAUSE" "$REF" >"$FIXTURE/.operator/last-rearm"; }

rung() { # N : run the script from the fixture, merged output
  (cd "$FIXTURE" && "$REPO_ROOT/scripts/demo-rung-$1.sh")
}

strip_ansi() { sed 's/\x1b\[[0-9;]*[A-Za-z]//g' <<<"$1"; }

# no line of the (ANSI-stripped) text is longer than STAGE_COLS
assert_fits() {
  local line text
  text="$(strip_ansi "$1")"
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if ((${#line} > STAGE_COLS)); then printf 'line over %s columns (%s): %s\n' "$STAGE_COLS" "${#line}" "$line" >&2; return 1; fi
  done <<<"$text"
}
