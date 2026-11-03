#!/usr/bin/env bash
# Evidence that a second build-all changed nothing.
#   scripts/idempotency.sh snapshot FILE        record UIDs (and pod restart counts)
#   scripts/idempotency.sh compare BEFORE AFTER  exit 1 and print the differences if any
# Recorded: the UID of every Deployment, StatefulSet, Service and Secret in the platform
# namespaces, and the UID and restartCount of every pod. Helm's own output cannot show
# this, because 'helm upgrade --install' prints no per-resource lines.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

snapshot() {
  local out="$1" ns
  load_env
  require_context
  : > "$out"
  for ns in "$NS_ARGOCD" "$NS_ROLLOUTS" "$NS_MONITORING" "$NS_AIOPS"; do
    k get namespace "$ns" >/dev/null 2>&1 || continue
    k get deployments,statefulsets,services,secrets -n "$ns" -o json \
      | jq -r '.items[] | "\(.kind) \(.metadata.namespace)/\(.metadata.name) uid=\(.metadata.uid)"' >> "$out"
    k get pods -n "$ns" -o json \
      | jq -r '.items[] | "Pod \(.metadata.namespace)/\(.metadata.name) uid=\(.metadata.uid) restarts=\([.status.containerStatuses[]?.restartCount] | add // 0)"' >> "$out"
  done
  sort -o "$out" "$out"
  [[ -s "$out" ]] || die "snapshot is empty: nothing to compare"
  log_info "snapshot: $(wc -l < "$out") objects recorded in $out"
}

compare() {
  local before="$1" after="$2"
  [[ -s "$before" && -s "$after" ]] || die "compare needs two non-empty snapshots"
  if diff -u "$before" "$after"; then
    log_info "compare: identical ($(wc -l < "$before") objects, UIDs and restart counts unchanged)"
  else
    log_error "compare: the second build-all changed or recreated objects (diff above)"
    return 1
  fi
}

case "${1:-}" in
  snapshot) snapshot "${2:?FILE}" ;;
  compare)  compare "${2:?BEFORE}" "${3:?AFTER}" ;;
  *) die "usage: idempotency.sh snapshot FILE | compare BEFORE AFTER" ;;
esac
