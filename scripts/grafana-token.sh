#!/usr/bin/env bash
# Give cdevents-sim a Grafana token: service account "cdevents-sim" (Editor) plus a token,
# stored as Secret aiops/cdevents-grafana (key: token). Needs Grafana up, so build-all runs it
# (make grafana-token) after kps-install, not inside secrets-base.
#
# Idempotent: when the Secret already holds a token Grafana accepts, nothing changes. Otherwise
# the service account is reused (created when missing), its old token is deleted and a new one
# is made. The admin password and the token never appear in process arguments or output:
# curl reads its credentials from a config file descriptor.
#
#   scripts/grafana-token.sh
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=scripts/secrets.sh
. "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"

SA_NAME=cdevents-sim
TOKEN_NAME=cdevents-sim

# gapi_admin METHOD PATH [JSON_BODY] -> response body on stdout; non-2xx fails
gapi_admin() {
  local method="$1" path="$2" body="${3:-}" args=()
  [[ -z "$body" ]] || args=(-H 'Content-Type: application/json' -d "$body")
  curl -sf --max-time 15 -X "$method" "${args[@]}" \
    -K <(printf 'user = "admin:%s"\n' "$GRAFANA_ADMIN_PASSWORD") "${GRAFANA_HOST_URL}${path}"
}

# token_works TOKEN : true when Grafana accepts it. /api/user, not /api/org: this Grafana lets
# anonymous Viewers read /api/org, so a rejected token would still pass there.
token_works() {
  curl -sf --max-time 15 -o /dev/null \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$1") "${GRAFANA_HOST_URL}/api/user"
}

stored_token() { # prints the token in the Secret, or nothing
  k get secret cdevents-grafana -n "$NS_AIOPS" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true
}

main() {
  load_env
  cluster_lock
  require_context
  trap _cleanup_secret_dir EXIT
  _have GRAFANA_ADMIN_PASSWORD || die "GRAFANA_ADMIN_PASSWORD is missing in .env"
  wait_for "Grafana API at $GRAFANA_HOST_URL" 120 curl -sf --max-time 5 "${GRAFANA_HOST_URL}/api/health"

  local cur
  cur="$(stored_token)"
  if [[ -n "$cur" ]] && token_works "$cur"; then
    log_info "skip: Secret $NS_AIOPS/cdevents-grafana holds a token Grafana accepts"
    return 0
  fi

  local sa_id
  sa_id="$(gapi_admin GET "/api/serviceaccounts/search?query=${SA_NAME}" \
    | jq -r --arg n "$SA_NAME" '[.serviceAccounts[]? | select(.name == $n)][0].id // empty')"
  if [[ -z "$sa_id" ]]; then
    sa_id="$(gapi_admin POST /api/serviceaccounts "{\"name\":\"${SA_NAME}\",\"role\":\"Editor\"}" | jq -r '.id')"
    log_info "created service account $SA_NAME (Editor)"
  else
    log_info "reusing service account $SA_NAME"
  fi
  [[ "$sa_id" =~ ^[0-9]+$ ]] || die "could not resolve the $SA_NAME service account id"

  local tid
  while read -r tid; do
    [[ -z "$tid" ]] || gapi_admin DELETE "/api/serviceaccounts/${sa_id}/tokens/${tid}" >/dev/null
  done < <(gapi_admin GET "/api/serviceaccounts/${sa_id}/tokens" | jq -r --arg n "$TOKEN_NAME" '.[] | select(.name == $n) | .id')

  local key
  key="$(gapi_admin POST "/api/serviceaccounts/${sa_id}/tokens" "{\"name\":\"${TOKEN_NAME}\"}" | jq -r '.key // empty')"
  [[ -n "$key" ]] || die "Grafana returned no token"
  _new_secret_dir
  _put token "$key"
  _apply_secret "$NS_AIOPS" cdevents-grafana
}

main "$@"
