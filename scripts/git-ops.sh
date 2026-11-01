#!/usr/bin/env bash
# Guarded Git operations for the operator scripts (seed-history, rearm, fix, ...).
#
# Source it for the functions, or run it:
#   scripts/git-ops.sh operator-clone
#   scripts/git-ops.sh disarm [--image TAG] [--git-only]
#   scripts/git-ops.sh bump
#
# Everything works in $OPERATOR_DIR, a separate HTTPS clone of the tracked branch, never in
# the main checkout. Its credential helper is `gh auth git-credential`, which uses Luke's gh
# login or GH_TOKEN when that is set, so a push never depends on an unlocked SSH agent (P13).
# Operator git runs without the user's global and system git config, so a global
# `url.<ssh>.insteadOf https://github.com/` can't turn the HTTPS remote back into SSH;
# op_sync also checks the fetch and push URLs it resolves to.
# Argo CD is driven with kubectl only: no argocd CLI session (it expires after 24 h).
#
# Overrides for tests and forks: OPERATOR_REMOTE (clone URL), ENSURE_IMAGE (default
# scripts/ensure-image.sh), ARGO_REFRESH (normal|hard), ARGO_WAIT_S, HEALTH_WAIT_S.
#
# Exit codes: 1 generic, 3 wrong context, 4 wait timed out, 5 cluster lock held.

set -euo pipefail
GIT_OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$GIT_OPS_DIR/common.sh"

ENSURE_IMAGE="${ENSURE_IMAGE:-$GIT_OPS_DIR/ensure-image.sh}"
PUSH_ATTEMPTS=3

# ---------------------------------------------------------------- plumbing
# git for the operator clone: no global or system config (no insteadOf rewrites, no global
# hooksPath or credential helpers). The clone's own config carries the identity and helper.
_opgit() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 git "$@"; }
_og() { _opgit -C "$OPERATOR_DIR" "$@"; }
_ogq() { quiet _opgit -C "$OPERATOR_DIR" "$@"; } # silent unless it fails

op_expected_remote() { printf '%s' "${OPERATOR_REMOTE:-https://github.com/${REPO_SLUG}.git}"; }

# The user's commit identity, copied into the clone, since operator git ignores the global config.
_op_identity() {
  local key val
  for key in user.name user.email; do
    [[ -n "$(_og config --local --get "$key" 2>/dev/null || true)" ]] && continue
    val="$(git config --global --get "$key" 2>/dev/null || true)"
    [[ -n "$val" ]] || die "operator clone: no $key in the clone or the global git config"
    _og config --local "$key" "$val"
  done
}

# Both URLs git will really use for origin must be the expected remote (HTTPS on GitHub).
op_check_remote() {
  local want fetch push
  want="$(op_expected_remote)"
  fetch="$(_og ls-remote --get-url origin 2>/dev/null || true)"
  push="$(_og remote get-url --push origin 2>/dev/null || true)"
  [[ "$fetch" == "$want" && "$push" == "$want" ]] \
    || die "operator clone: origin resolves to '$fetch' (fetch) and '$push' (push), expected $want"
}

# Throw away local commits that never reached origin (a failed or interrupted push), so
# the next script doesn't push them along with its own.
op_reset_to_origin() {
  _ogq fetch --quiet origin "$TRACKED_BRANCH" || return 1
  _ogq reset --quiet --hard "refs/remotes/origin/$TRACKED_BRANCH"
}

# A path relative to the operator clone, unless it is already absolute.
op_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$OPERATOR_DIR" "$1" ;;
  esac
}

# True when the operator clone exists and is not the main checkout (a push from the
# main checkout would race the developer's own work).
op_configured() {
  [[ -n "${OPERATOR_DIR:-}" && -d "$OPERATOR_DIR/.git" ]] || return 1
  [[ "$(cd "$OPERATOR_DIR" && pwd -P)" != "$(cd "$(main_root)" && pwd -P)" ]]
}

op_require_configured() {
  op_configured || die "operator clone is not set up (OPERATOR_DIR='${OPERATOR_DIR:-}'); run: make operator-clone"
}

# ------------------------------------------------------------ the clone
# op_clone : clone if missing, set the credential helper for this clone only, install the
# pre-commit hook from PRECOMMIT_HOOK_SRC (warn and skip when it is unset or missing).
op_clone() {
  [[ -n "${OPERATOR_DIR:-}" ]] || die "OPERATOR_DIR is not set"
  local remote hook
  remote="$(op_expected_remote)"
  if [[ ! -d "$OPERATOR_DIR/.git" ]]; then
    mkdir -p "$(dirname "$OPERATOR_DIR")"
    quiet _opgit clone --quiet --branch "$TRACKED_BRANCH" "$remote" "$OPERATOR_DIR"
  fi
  op_require_configured
  _op_identity
  # An empty first value resets any helper inherited from the global config.
  _og config --local --unset-all credential.https://github.com.helper 2>/dev/null || true
  _og config --local --add credential.https://github.com.helper ''
  _og config --local --add credential.https://github.com.helper '!gh auth git-credential'
  hook="$OPERATOR_DIR/.git/hooks/pre-commit"
  if [[ -n "${PRECOMMIT_HOOK_SRC:-}" && -f "$PRECOMMIT_HOOK_SRC" ]]; then
    mkdir -p "$(dirname "$hook")"
    install -m 0755 "$PRECOMMIT_HOOK_SRC" "$hook"
    log_info "operator clone ready, pre-commit hook installed"
  else
    log_warn "PRECOMMIT_HOOK_SRC is unset or missing; skipping the pre-commit hook (operator pushes stay refused until it is installed)"
  fi
}

# op_sync : clone if missing; refuse a dirty tree, the wrong branch, a missing hook or a
# non-HTTPS remote; drop unpushed local commits; fast-forward to origin.
op_sync() {
  local ahead
  [[ -d "${OPERATOR_DIR:-}/.git" ]] || op_clone
  op_require_configured
  (cd "$OPERATOR_DIR" && require_branch "$TRACKED_BRANCH") || return 1
  (cd "$OPERATOR_DIR" && require_clean_tree) || return 1
  [[ -x "$OPERATOR_DIR/.git/hooks/pre-commit" ]] \
    || die "pre-commit hook is missing in the operator clone; set PRECOMMIT_HOOK_SRC and run: make operator-clone"
  op_check_remote
  _op_identity
  _ogq fetch --quiet origin "$TRACKED_BRANCH"
  ahead="$(_og rev-list --count "refs/remotes/origin/$TRACKED_BRANCH..HEAD")"
  if ((ahead > 0)); then
    log_warn "dropped unpushed commit(s): $ahead"
    _ogq reset --quiet --hard "refs/remotes/origin/$TRACKED_BRANCH"
  fi
  _ogq merge --ff-only --quiet "refs/remotes/origin/$TRACKED_BRANCH"
}

# ------------------------------------------------------------ commit and push
# op_push : push HEAD to the tracked branch. On a rejection, rebase onto the new tip and
# try again, up to PUSH_ATTEMPTS times. Never --force, never --no-verify.
op_push() {
  local attempt out=""
  for ((attempt = 1; attempt <= PUSH_ATTEMPTS; attempt++)); do
    if out="$(_og push --quiet origin "HEAD:refs/heads/$TRACKED_BRANCH" 2>&1)"; then
      return 0
    fi
    ((attempt < PUSH_ATTEMPTS)) || break
    if ! _ogq pull --rebase --quiet origin "$TRACKED_BRANCH"; then
      _og rebase --abort >/dev/null 2>&1 || true
      op_reset_to_origin || true
      die "could not rebase onto origin/$TRACKED_BRANCH"
    fi
  done
  # Git's own output (remote URL, ref lines) stays off the stage terminal.
  if stage_on; then _stage_keep "$out"; else printf '%s\n' "$out" >&2; fi
  op_reset_to_origin || true
  die "push to $TRACKED_BRANCH failed after $PUSH_ATTEMPTS attempts"
}

# op_commit_push MSG FILES... : take the cluster lock, commit exactly FILES, push, print the new SHA.
op_commit_push() {
  local msg="$1"
  shift
  (($# >= 1)) || die "op_commit_push: no files given"
  op_require_configured
  cluster_lock
  _ogq add -- "$@"
  if _og diff --cached --quiet; then
    die "op_commit_push: nothing to commit"
  fi
  if ! _ogq commit --quiet -m "$msg"; then
    _og reset --quiet --hard HEAD
    die "commit was refused (pre-commit hook?)"
  fi
  op_push
  _og rev-parse HEAD
}

# ------------------------------------------------------------ Argo CD (kubectl only)
# argo_refresh_and_wait APP SHA TIMEOUT_S : ask for a refresh, then wait until the
# Application is Synced at SHA and its last operation Succeeded.
argo_refresh_and_wait() {
  local app="$1" sha="$2" timeout="${3:-${ARGO_WAIT_S:-180}}"
  k annotate application "$app" -n "$NS_ARGOCD" \
    "argocd.argoproj.io/refresh=${ARGO_REFRESH:-normal}" --overwrite >/dev/null
  stage_wait "$app synced" "$timeout" _argo_synced_at "$app" "$sha"
}

_argo_synced_at() { # APP SHA
  local got
  got="$(k get application "$1" -n "$NS_ARGOCD" \
    -o jsonpath='{.status.sync.revision} {.status.sync.status} {.status.operationState.phase}')"
  [[ "$got" == "$2 Synced Succeeded" ]]
}

_app_health_is() { # APP STATE
  [[ "$(k get application "$1" -n "$NS_ARGOCD" -o jsonpath='{.status.health.status}')" == "$2" ]]
}

# op_wait_health APP STATE [TIMEOUT_S]
op_wait_health() {
  stage_wait "$1 $2" "${3:-${HEALTH_WAIT_S:-300}}" _app_health_is "$1" "$2"
}

# op_wait_fleet_disarmed [TIMEOUT_S] : wait until check_fleet_disarmed passes (every Ready
# pod reads CONFIG_HEALTHY and the 1 m success rate meets the SLO; the rate can hold an
# earlier incident's errors for up to a minute). On timeout, print the reason and exit 4.
op_wait_fleet_disarmed() {
  local rc=0
  FLEET_WAIT_S="${FLEET_WAIT_S:-10}" stage_wait "fleet disarmed" "${1:-${FLEET_DISARMED_WAIT_S:-150}}" \
    check_fleet_disarmed || rc=$?
  if ((rc != 0)); then
    FLEET_WAIT_S=1 check_fleet_disarmed >/dev/null || true
    exit "$rc"
  fi
}

# ------------------------------------------------------------ YAML values
# yaml_set FILE KEY VALUE : set a string value with yq, keeping the other keys and comments.
# KEY is a yq path such as .data.UPSTREAM_TIMEOUT_MS. FILE is relative to the operator clone.
yaml_set() {
  local file
  file="$(op_path "$1")"
  [[ -w "$file" ]] || die "yaml_set: cannot write $file"
  YQ_VALUE="$3" yq -i "$2 = strenv(YQ_VALUE)" "$file"
}

yaml_get() { # FILE KEY
  yq -r "$2" "$(op_path "$1")"
}

config_value_get() { yaml_get "$CONFIG_FILE" ".data.${CONFIG_KEY}"; }
config_value_set() { yaml_set "$CONFIG_FILE" ".data.${CONFIG_KEY}" "$1"; }

_cv_path='.spec.template.metadata.annotations[strenv(CONFIG_VERSION_ANNOTATION)]'

config_version_get() { yaml_get "$ROLLOUT_FILE" "$_cv_path"; }

# config_version_bump : +1, keeps the quoted string; prints the new number.
config_version_bump() {
  local cur
  cur="$(config_version_get)"
  [[ "$cur" =~ ^[0-9]+$ ]] || die "config-version is '$cur', expected a number"
  cur=$((10#$cur + 1))
  yaml_set "$ROLLOUT_FILE" "$_cv_path" "$cur"
  printf '%s\n' "$cur"
}

_image_sel='.images[] | select(.name == "checkout") | .newTag'

image_tag_get() { yaml_get "$KUSTOMIZATION_FILE" "$_image_sel"; }
image_tag_set() { yaml_set "$KUSTOMIZATION_FILE" "(${_image_sel})" "$1"; }

# ------------------------------------------------------------ disarm and bump
# op_disarm [--image TAG] [--git-only]
# One commit: value back to CONFIG_HEALTHY (and config-version +1) when it differs, and the
# image tag to TAG when given and different (P14). No-op when nothing differs. Sets DISARM_SHA.
op_disarm() {
  local image="" git_only=0 files=() msg beats=() cv b
  while (($#)); do
    case "$1" in
      --image) image="${2:?--image needs a tag}"; shift 2 ;;
      --git-only) git_only=1; shift ;;
      *) die "disarm: unknown argument '$1'" ;;
    esac
  done
  DISARM_SHA=""
  if ((git_only)) && ! op_configured; then
    log_warn "disarm --git-only: no operator clone (run make operator-clone to push); skipping"
    return 0
  fi
  op_sync
  if [[ "$(config_value_get)" != "$CONFIG_HEALTHY" ]]; then
    config_value_set "$CONFIG_HEALTHY"
    cv="$(config_version_bump)"
    files+=("$CONFIG_FILE" "$ROLLOUT_FILE")
    beats+=("pushed: config $CONFIG_HEALTHY, cv $cv")
  fi
  if [[ -n "$image" && "$(image_tag_get)" != "$image" ]]; then
    image_tag_set "$image"
    files+=("$KUSTOMIZATION_FILE")
    beats+=("pushed: image $image")
  fi
  if ((${#files[@]} == 0)); then
    # Git is disarmed, but an earlier disarm or fix may not have finished rolling out
    # (Review Focus 1): wait until the cluster is Healthy and no Ready pod reads the armed value.
    if ((!git_only)); then
      op_wait_health checkout Healthy
      op_wait_fleet_disarmed
    fi
    beat "already disarmed"
    return 0
  fi
  msg="chore(demo): disarm checkout"
  DISARM_SHA="$(op_commit_push "$msg" "${files[@]}")"
  for b in "${beats[@]}"; do beat "$b"; done
  emit_change_event "$DISARM_SHA" disarm "$msg" ""
  ((git_only)) && return 0
  argo_refresh_and_wait checkout "$DISARM_SHA"
  op_wait_health checkout Healthy
  beat "healthy"
}

# op_bump : next patch tag in the kustomization only, ensure-image, push, refresh. Sets BUMP_SHA.
op_bump() {
  local cur next
  cur="$(image_tag_get)"
  [[ "$cur" =~ ^(v[0-9]+\.[0-9]+\.)([0-9]+)$ ]] || die "bump: image tag '$cur' is not vX.Y.Z"
  next="${BASH_REMATCH[1]}$((BASH_REMATCH[2] + 1))"
  if stage_on; then
    quiet "$ENSURE_IMAGE" checkout "$next"
  else
    "$ENSURE_IMAGE" checkout "$next" >&2
  fi
  image_tag_set "$next"
  BUMP_SHA="$(op_commit_push "chore(checkout): bump image to $next" "$KUSTOMIZATION_FILE")"
  beat "pushed: image $next"
  emit_change_event "$BUMP_SHA" image "bump image to $next" ""
  argo_refresh_and_wait checkout "$BUMP_SHA"
  beat "synced"
}

# ------------------------------------------------------------ dispatcher
_git_ops_main() {
  local cmd="${1:-}"
  shift || true
  load_env
  case "$cmd" in
    operator-clone) op_clone ;;
    disarm)
      local arg git_only=0
      for arg in "$@"; do [[ "$arg" == "--git-only" ]] && git_only=1; done
      ((git_only)) || require_context
      cluster_lock
      machine_init last-disarm
      op_disarm "$@"
      [[ -z "${DISARM_SHA:-}" ]] || machine_line disarm "$DISARM_SHA"
      ;;
    bump)
      require_context
      cluster_lock
      machine_init last-bump
      op_sync
      op_bump
      machine_line bump "$BUMP_SHA"
      ;;
    *) die "usage: git-ops.sh operator-clone | disarm [--image TAG] [--git-only] | bump" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _git_ops_main "$@"
fi
