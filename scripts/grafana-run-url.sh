#!/usr/bin/env bash
# Print a kiosk URL for the trust-ladder dashboard.
#   scripts/grafana-run-url.sh --kiosk          live: refresh 5s, last 30 minutes (GRAFANA_KIOSK_URL)
#   scripts/grafana-run-url.sh <window file>    a saved run: from SINCE-5min to UNTIL+5min, epoch ms,
#                                               no refresh (GRAFANA_RUN_URL)
# The window file holds SINCE=<epoch s> and UNTIL=<epoch s> lines (P26). It is read as data,
# never sourced. Grafana keeps annotations in its database, so a run can be reviewed later only
# while the cluster has not been rebuilt.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

base_url() {
  printf '%s/d/%s/%s?orgId=1&kiosk&_dash.hideTimePicker&_dash.hideVariables&_dash.hideLinks' \
    "$GRAFANA_HOST_URL" "$GRAFANA_DASHBOARD_UID" "$GRAFANA_DASHBOARD_SLUG"
}

# window_value FILE KEY : the integer after KEY=, or nothing
window_value() {
  sed -n "s/^$2=\([0-9][0-9]*\)\$/\1/p" "$1" | tail -1
}

main() {
  local arg="${1:-}" since until
  load_env
  case "$arg" in
    --kiosk) printf '%s&refresh=5s&from=now-30m&to=now\n' "$(base_url)" ;;
    "")      die "usage: grafana-run-url.sh --kiosk | <window file>" ;;
    *)
      [[ -r "$arg" ]] || die "window file not readable: $arg"
      since="$(window_value "$arg" SINCE)"
      until="$(window_value "$arg" UNTIL)"
      [[ -n "$since" && -n "$until" ]] || die "window file needs SINCE=<epoch> and UNTIL=<epoch> lines"
      printf '%s&from=%s&to=%s\n' "$(base_url)" "$(( (since - 300) * 1000 ))" "$(( (until + 300) * 1000 ))"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
