#!/usr/bin/env bash
# The bridge's test hooks: the optional Secret bridge-env (Task 4.6 failure paths).
#
#   scripts/bridge-hooks.sh check   exit 1 while bridge-env exists, naming its keys (never values)
#   scripts/bridge-hooks.sh clear   delete bridge-env, restart the bridge, wait for /status
#
# failure-paths.sh sets TEST_CONFIDENCE_THRESHOLD or TEST_HOLMES_TIMEOUT_S there and removes the
# Secret in its EXIT trap. A killed run (SIGKILL, laptop sleep, kind restart) leaves it behind,
# and then every live incident is refused or handed off. preflight fails on it (every rung),
# /status shows test_hooks_active, and a reset runs `clear`.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# bridge_env_keys : the key names in bridge-env, one per line; nothing when it is absent.
# Returns 1 when the cluster can't be read.
bridge_env_keys() {
  local json
  json="$(k get secret bridge-env -n "$NS_AIOPS" --ignore-not-found -o json)" || return 1
  [[ -n "$json" ]] || return 0
  jq -r '(.data // {}) | keys[]' <<<"$json"
}

cmd_check() {
  local keys
  keys="$(bridge_env_keys)" || die "cannot read Secret bridge-env in $NS_AIOPS"
  if [[ -n "$keys" ]]; then
    log_error "Secret bridge-env is present (test hooks: $(tr '\n' ' ' <<<"$keys" | sed 's/ $//')); run make bridge-hooks-clear"
    return 1
  fi
  log_info "no bridge-env Secret: no test hooks"
}

bridge_ready() {
  curl -sf --max-time 5 "127.0.0.1:${PORT_BRIDGE}/status" \
    | jq -e '.test_hooks_active == false' >/dev/null
}

cmd_clear() {
  cluster_lock
  if [[ -z "$(bridge_env_keys)" ]]; then
    log_info "no bridge-env Secret: nothing to clear"
    return 0
  fi
  k delete secret bridge-env -n "$NS_AIOPS" --ignore-not-found >/dev/null
  # Argo self-heals the Deployment, so restart by deleting the pod, not by editing the template.
  k delete pod -n "$NS_AIOPS" -l app=bridge --wait=true >/dev/null
  k rollout status deploy/bridge -n "$NS_AIOPS" --timeout=120s >/dev/null
  wait_for "bridge /status answers with no test hook active" 90 bridge_ready
  log_info "bridge-env removed; the bridge restarted without test hooks"
}

main() {
  load_env
  require_context
  case "${1:-}" in
    check) cmd_check ;;
    clear) cmd_clear ;;
    *) die "usage: bridge-hooks.sh check|clear" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
