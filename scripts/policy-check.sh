#!/usr/bin/env bash
# The same checks the required `policy-check` GitHub Action runs, for a laptop (spec 7.5).
#
#   scripts/policy-check.sh                                     golden-path labels on every app
#   scripts/policy-check.sh --base SHA --head SHA [options]     plus the auto-fix rules
#
# Options (all optional):
#   --body-file FILE      the PR body; default: the message of --head's commit
#   --author-login LOGIN  default: BOT_LOGIN (a bot-style fix branch). Any other login skips
#                         the auto-fix rules, as the Action does for human PRs
#   --author-type TYPE    default: Bot
#   --tracked-ref REF     where "seen before" and "on the branch" are asked; default TRACKED_BRANCH
#   --policy-dir DIR      the Rego to enforce; default policy/ in this checkout. The Action
#                         passes the base ref's copy, never the head's.
#
# Needs conftest, kubectl (for `kubectl kustomize`) and PyYAML (or uv). No cluster.
# Exit codes: 1 a rule denied or a tool failed, 2 bad usage.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$HERE/common.sh"
load_env
ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"

base="" head="" body_file="" author_login="" author_type="Bot"
tracked_ref="${TRACKED_BRANCH:-build/demo}" policy_dir="$ROOT/policy"
usage() { echo "usage: policy-check.sh [--base SHA --head SHA] [--body-file F] [--author-login L] [--author-type T] [--tracked-ref R] [--policy-dir D]" >&2; exit 2; }
while (($#)); do
  case "$1" in
    --base) base="${2:?}"; shift 2 ;;
    --head) head="${2:?}"; shift 2 ;;
    --body-file) body_file="${2:?}"; shift 2 ;;
    --author-login) author_login="${2:?}"; shift 2 ;;
    --author-type) author_type="${2:?}"; shift 2 ;;
    --tracked-ref) tracked_ref="${2:?}"; shift 2 ;;
    --policy-dir) policy_dir="${2:?}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$base" && -z "$head" || -z "$base" && -n "$head" ]] && { echo "policy-check: --base and --head go together" >&2; usage; }

command -v conftest >/dev/null || die "conftest not found"
command -v kubectl >/dev/null || die "kubectl not found (needed for kubectl kustomize)"
policy_dir="$(cd "$policy_dir" && pwd)"
if [[ -n "$base" ]] && ! git -C "$ROOT" rev-parse --verify -q "$tracked_ref^{commit}" >/dev/null \
    && git -C "$ROOT" rev-parse --verify -q "origin/$tracked_ref^{commit}" >/dev/null; then
  tracked_ref="origin/$tracked_ref"   # a clone with no local copy of the tracked branch
fi

py=(python3)
if ! python3 -c 'import yaml' 2>/dev/null; then
  command -v uv >/dev/null || die "PyYAML is missing and uv is not available"
  py=(uv run --quiet --with pyyaml python3)
fi

rc=0
echo "policy-check: golden path (policy: $policy_dir)"
for d in "$ROOT"/apps/*/; do
  [[ -f "$d/kustomization.yaml" ]] || continue
  echo "policy-check: ${d#"$ROOT"/}"
  kubectl kustomize "$d" | conftest test --policy "$policy_dir" --namespace goldenpath --parser yaml - || rc=1
done

if [[ -n "$base" ]]; then
  author_login="${author_login:-$BOT_LOGIN}"
  if [[ "$author_login" != "$BOT_LOGIN" ]]; then
    echo "policy-check: author is not $BOT_LOGIN, auto-fix rules skipped"
  else
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    if [[ -z "$body_file" ]]; then
      body_file="$tmp/body.md"
      git -C "$ROOT" log -1 --format=%B "$head" >"$body_file"
    fi
    echo "policy-check: auto-fix rules for ${base:0:7}..${head:0:7}"
    if "${py[@]}" "$policy_dir/facts/facts.py" --repo "$ROOT" --base "$base" --head "$head" \
        --body-file "$body_file" --author-login "$author_login" --author-type "$author_type" \
        --tracked-ref "$tracked_ref" >"$tmp/facts.json"; then
      conftest test "$tmp/facts.json" --policy "$policy_dir" --namespace autofix \
        -d "$policy_dir/data" || rc=1
    else
      echo "policy-check: facts could not be established (fails closed)" >&2
      rc=1
    fi
  fi
fi
exit "$rc"
