#!/usr/bin/env bash
# Point the demo at your own fork: set REPO_SLUG, BOT_LOGIN and PROMOTION_TEAM in demo.env, then
# rewrite everything that names them (the Applications' repoURL, CODEOWNERS, the policy's agent
# login and the bridge Deployment's two env values). Idempotent. Offline: it edits files only.
#
#   scripts/configure-fork.sh [--root DIR] [--repo-slug OWNER/REPO] [--bot-login NAME[bot]]
#                             [--promotion-team @OWNER/TEAM]
#   make configure-fork REPO_SLUG=you/argoconna26 BOT_LOGIN=your-app[bot] PROMOTION_TEAM=@you/board
#
# Any value you leave out keeps its current demo.env value. Commit the result to your fork, then
# `make consistency` (it fails if anything still names the old values).
#
# Not rewritten: the unit tests' fixtures and the code defaults in bridge/ and scripts/ that the
# Deployment's env values always override. They keep the upstream names and don't affect a run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
slug="" login="" team=""

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}
fail() { printf 'configure-fork: %s\n' "$*" >&2; exit 2; }

while (($#)); do
  case "$1" in
    --root) [[ $# -ge 2 ]] || fail "--root needs a value"; ROOT="$2"; shift 2 ;;
    --repo-slug) [[ $# -ge 2 ]] || fail "--repo-slug needs a value"; slug="$2"; shift 2 ;;
    --bot-login) [[ $# -ge 2 ]] || fail "--bot-login needs a value"; login="$2"; shift 2 ;;
    --promotion-team) [[ $# -ge 2 ]] || fail "--promotion-team needs a value"; team="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) fail "unknown argument '$1' (see --help)" ;;
  esac
done

DEMO_ENV="$ROOT/demo.env"
[[ -f "$DEMO_ENV" ]] || fail "no demo.env under $ROOT"

# env_get KEY : the value of KEY= in demo.env (last assignment wins).
env_get() { sed -n "s/^$1=//p" "$DEMO_ENV" | tail -1; }

[[ -n "$slug$login$team" ]] || fail "give at least one of --repo-slug, --bot-login, --promotion-team"
[[ -n "$slug" ]] || slug="$(env_get REPO_SLUG)"
[[ -n "$login" ]] || login="$(env_get BOT_LOGIN)"
[[ -n "$team" ]] || team="$(env_get PROMOTION_TEAM)"

# Validate before touching a file. GitHub names: letters, digits, '-', '_' and '.'.
name='[A-Za-z0-9._-]+'
[[ "$slug" =~ ^$name/$name$ ]] || fail "REPO_SLUG '$slug' is not OWNER/REPO"
[[ "$login" =~ ^[A-Za-z0-9-]+\[bot\]$ ]] || fail "BOT_LOGIN '$login' is not <app-name>[bot]"
[[ "$team" =~ ^@$name/$name$ ]] || fail "PROMOTION_TEAM '$team' is not @OWNER/TEAM"

changed=()

# store FILE CONTENT : replace FILE with CONTENT (every line newline-terminated) only if it differs,
# keeping the original's mode and a missing final newline.
store() {
  local file="$1" out="$2" tmp
  [[ -n "$(tail -c1 "$file")" ]] && out="${out%$'\n'}"
  tmp="$(mktemp "$file.XXXXXX")"
  printf '%s' "$out" > "$tmp"
  if cmp -s "$tmp" "$file"; then rm -f "$tmp"; else
    chmod --reference="$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"; changed+=("${file#"$ROOT"/}")
  fi
}

# rewrite FILE FN : run FN over the file line by line (FN prints the new line).
rewrite() {
  local file="$1" fn="$2" line out=""
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    out+="$("$fn" "$line")"$'\n'
  done < "$file"
  store "$file" "$out"
}

fn_demo_env() {
  case "$1" in
    REPO_SLUG=*) printf 'REPO_SLUG=%s' "$slug" ;;
    BOT_LOGIN=*) printf 'BOT_LOGIN=%s' "$login" ;;
    PROMOTION_TEAM=*) printf 'PROMOTION_TEAM=%s' "$team" ;;
    *) printf '%s' "$1" ;;
  esac
}

fn_repourl() {
  if [[ "$1" =~ ^([[:space:]-]*repoURL:[[:space:]]*)\"?https://github\.com/[^[:space:]\"]+\"?([[:space:]]*(#.*)?)$ ]]; then
    printf '%shttps://github.com/%s.git%s' "${BASH_REMATCH[1]}" "$slug" "${BASH_REMATCH[2]}"
  else
    printf '%s' "$1"
  fi
}

fn_codeowners() {
  if [[ "$1" =~ ^[[:space:]]*(#|$) ]]; then printf '%s' "$1"
  elif [[ "$1" =~ ^([^[:space:]]+[[:space:]]+)@[^[:space:]]+ ]]; then printf '%s%s' "${BASH_REMATCH[1]}" "$team"
  else printf '%s' "$1"; fi
}

fn_agent() {
  if [[ "$1" =~ ^agent_login:[[:space:]]*[^[:space:]#]+(.*)$ ]]; then
    printf 'agent_login: %s%s' "$login" "${BASH_REMATCH[1]}"
  else printf '%s' "$1"; fi
}

# The bridge Deployment takes REPO_SLUG and BOT_LOGIN as env entries, one line
# (`- {name: N, value: V}`) or two (`- name: N` then `value: V`). Rewritten with a small
# state machine, so this function reads the whole file itself.
rewrite_bridge_env() {
  local file="$ROOT/bridge/deploy/deployment.yaml" line out="" pending="" val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$pending" ]]; then
      if [[ "$line" =~ ^([[:space:]]*value:[[:space:]]*)[^#]*$ ]]; then
        [[ "$pending" == REPO_SLUG ]] && val="$slug" || val="\"$login\""
        line="${BASH_REMATCH[1]}$val"
      fi
      pending=""
    elif [[ "$line" =~ name:[[:space:]]*(REPO_SLUG|BOT_LOGIN)[[:space:]]*(,|$) ]]; then
      local which="${BASH_REMATCH[1]}"
      [[ "$which" == REPO_SLUG ]] && val="$slug" || val="\"$login\""
      if [[ "$line" =~ ^(.*value:[[:space:]]*)[^}]*[^[:space:]}](.*)$ ]]; then
        line="${BASH_REMATCH[1]}$val${BASH_REMATCH[2]}"
      else
        pending="$which"
      fi
    fi
    out+="$line"$'\n'
  done < "$file"
  store "$file" "$out"
}

rewrite "$DEMO_ENV" fn_demo_env
if [[ -d "$ROOT/gitops" ]]; then
  while IFS= read -r -d '' f; do rewrite "$f" fn_repourl; done \
    < <(find "$ROOT/gitops" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)
fi
rewrite "$ROOT/.github/CODEOWNERS" fn_codeowners
rewrite "$ROOT/policy/data/agent.yaml" fn_agent
rewrite_bridge_env

if ((${#changed[@]})); then
  printf 'configure-fork: updated %s\n' "${changed[@]}"
else
  printf 'configure-fork: already configured, nothing to change\n'
fi
cat <<EOM

REPO_SLUG=$slug
BOT_LOGIN=$login
PROMOTION_TEAM=$team

Next steps:
  1. make consistency                 # must print "consistency: OK"
  2. git add -A && git commit -m "feat: configure the demo for my fork" && git push
  3. cp .env.example .env && chmod 600 .env   # then add an LLM key
  4. make operator-clone              # uses your own gh login (or GH_TOKEN with a fine-grained PAT)
  5. make build-all && make reset-demo
Rungs 2 and 3 also need your GitHub App, a promotion-board team and the rulesets;
see the README ("Run it from your own fork") and docs/github-setup.md.
EOM
