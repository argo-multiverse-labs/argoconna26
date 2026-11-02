# Helpers for promotion.bats. Builds on ops_helpers (bare "GitHub", operator clone, fake main
# checkout) and adds a stateful gh stub plus an aiops/autonomy.yaml on build/demo.
#
# gh stub state lives in $PROMO_STATE:
#   pr/N.json            {number,state,headRefName,headRefOid}   (state OPEN | CLOSED | MERGED)
#   body-N               the --body-file the PR was created with
#   comments-N           one line per `gh pr close --comment`
#   reviews-N.json       the REST reviews array (default [])
#   head-override-N      a SHA that `gh pr view` reports instead of the real head
#   diff-override-N      file names (one per line) that `gh pr diff` reports instead of the real diff
# Every gh call is appended to $CALLS as "gh <args>".

make_promotion_fixture() {
  make_ops_fixture
  PROMO_STATE="$BATS_TEST_TMPDIR/ghstate"
  mkdir -p "$PROMO_STATE/pr"
  export PROMO_STATE ORIGIN REAL_GIT OTHER CALLS
  _promotion_gh_stub
  seed_autonomy suggest
  export STAGE_COLS=30
}

# seed_autonomy LEVEL : put aiops/autonomy.yaml on origin's build/demo and sync the operator clone.
seed_autonomy() {
  mkdir -p "$OTHER/aiops"
  cat > "$OTHER/aiops/autonomy.yaml" <<YAML
apiVersion: aiops.example.dev/v1
kind: Autonomy
level: $1
since: "2026-11-02"
promotion: null
touchpoints: {suggest: 4, propose: 1, act: 1}   # steps a human must take
YAML
  "$REAL_GIT" -C "$OTHER" pull -q --ff-only origin build/demo
  "$REAL_GIT" -C "$OTHER" add aiops/autonomy.yaml
  "$REAL_GIT" -C "$OTHER" commit -q -m "seed autonomy $1"
  "$REAL_GIT" -C "$OTHER" push -q origin HEAD:refs/heads/build/demo
  "$REAL_GIT" -C "$OP" pull -q --ff-only origin build/demo
}

PROMO="$REPO_ROOT/scripts/promotion-pr.sh"

# promo ARGS... : run promotion-pr.sh from the fake main checkout.
promo() { ( cd "$FIXTURE" && "$PROMO" "$@" ); }

# autonomy_at REF KEY : a yq read of aiops/autonomy.yaml as of a ref in origin.
autonomy_at() {
  "$REAL_GIT" --git-dir="$ORIGIN" show "$1:aiops/autonomy.yaml" | yq -r "$2"
}
tip_autonomy() { autonomy_at refs/heads/build/demo "$1"; }

pr_state() { jq -r .state "$PROMO_STATE/pr/$1.json"; }
open_pr_count() { grep -l '"state": *"OPEN"' "$PROMO_STATE"/pr/*.json 2>/dev/null | wc -l; }
branch_of() { jq -r .headRefName "$PROMO_STATE/pr/$1.json"; }
gh_calls() { grep '^gh ' "$CALLS" || true; }

_promotion_gh_stub() {
  cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
# A stateful gh for promotion-pr.sh. See promotion_helpers.bash.
S="$PROMO_STATE"
echo "gh $*" >> "$CALLS"
jqexpr=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -q|--jq) jqexpr="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
emit() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr"; else cat; fi; }
getflag() { # NAME ARGS... : value after NAME
  local name="$1" i; shift
  local a=("$@")
  for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" = "$name" ] && { printf '%s' "${a[i+1]}"; return; }; done
}
diff_names() { # N
  if [ -f "$S/diff-override-$1" ]; then cat "$S/diff-override-$1"; return; fi
  b=$(jq -r .headRefName "$S/pr/$1.json")
  "$REAL_GIT" --git-dir="$ORIGIN" diff --name-only "refs/heads/build/demo...refs/heads/$b"
}
case "$1 $2" in
  "pr list")
    for f in "$S"/pr/*.json; do [ -f "$f" ] || continue; cat "$f"; done \
      | jq -s '[.[] | select(.state == "OPEN")]' | emit ;;
  "pr create")
    n=$(( $(cat "$S/next" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$S/next"
    head=$(getflag --head "$@")
    cp "$(getflag --body-file "$@")" "$S/body-$n"
    sha=$("$REAL_GIT" --git-dir="$ORIGIN" rev-parse "refs/heads/$head")
    jq -n --argjson n "$n" --arg h "$head" --arg sha "$sha" \
      '{number:$n, state:"OPEN", headRefName:$h, headRefOid:$sha, author:{login:"stub-author"}}' > "$S/pr/$n.json"
    echo "https://github.com/argo-multiverse-labs/argoconna26/pull/$n" ;;
  "pr close")
    n="$3"; c=$(getflag --comment "$@"); [ -z "$c" ] || echo "$c" >> "$S/comments-$n"
    jq '.state = "CLOSED"' "$S/pr/$n.json" > "$S/tmp" && mv "$S/tmp" "$S/pr/$n.json" ;;
  "pr view")
    n="$3"; [ -f "$S/pr/$n.json" ] || { echo "no pull request $n" >&2; exit 1; }
    if [ -f "$S/head-override-$n" ]; then
      jq --arg h "$(cat "$S/head-override-$n")" '.headRefOid = $h' "$S/pr/$n.json" | emit
    else emit < "$S/pr/$n.json"; fi ;;
  "pr diff") diff_names "$3" ;;
  "pr merge")
    n="$3"; want=$(getflag --match-head-commit "$@")
    cur=$(jq -r .headRefOid "$S/pr/$n.json")
    if [ -n "$want" ] && [ "$want" != "$cur" ]; then echo "head moved" >&2; exit 1; fi
    b=$(jq -r .headRefName "$S/pr/$n.json")
    "$REAL_GIT" -C "$OTHER" fetch -q origin
    "$REAL_GIT" -C "$OTHER" checkout -q -B build/demo origin/build/demo
    "$REAL_GIT" -C "$OTHER" merge -q --no-ff -m "Merge pull request #$n from argo-multiverse-labs/$b" "origin/$b"
    "$REAL_GIT" -C "$OTHER" push -q origin HEAD:refs/heads/build/demo
    jq '.state = "MERGED"' "$S/pr/$n.json" > "$S/tmp" && mv "$S/tmp" "$S/pr/$n.json" ;;
  "api orgs/"*"/teams/"*"/memberships/"*)
    # members: one login per line (default: stub-reviewer); anyone else is a 404.
    # membership-error: a transient failure to answer with instead (for example "Server Error (HTTP 502)").
    login="${2##*/}"
    if [ -s "$S/membership-error" ]; then echo "gh: $(cat "$S/membership-error")" >&2; exit 1; fi
    if grep -qx -- "$login" "$S/members" 2>/dev/null || { [ ! -f "$S/members" ] && [ "$login" = stub-reviewer ]; }; then
      if [ -s "$S/membership-state" ]; then emit <"$S/membership-state"; else echo '{"state":"active"}' | emit; fi
    else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
  "api repos/argo-multiverse-labs/argoconna26/pulls/"*)
    path="$2"; n="${path#*/pulls/}"; n="${n%%/*}"
    { cat "$S/reviews-$n.json" 2>/dev/null || echo '[]'; } | emit ;;
  *) echo "gh stub: unexpected: $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$STUBS/gh"
}
