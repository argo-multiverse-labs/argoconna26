#!/usr/bin/env bash
# Seed the demo history. Disarms first, so an armed branch never meets a fresh cluster
# (Review Focus 1), then makes two commits:
#   PR-242  tune the upstream timeout 2000 -> 200, config-version untouched (the canary is pre-armed)
#   docs    one harmless commit that touches only apps/pricing/README.md
# It stops before the bump. Prints (or, under STAGE=1, writes to .operator/last-seed):
#   cause: <PR-242 sha>   change_ref: CHG-XXXXXX
# STAGE=1: one short line per beat, no raw SHAs on the terminal.
set -euo pipefail
# shellcheck source=scripts/git-ops.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-ops.sh"

PR242_SUBJECT="PR-242: tune upstream timeout for faster failover"
DOCS_SUBJECT="docs: pricing service notes"
PRICING_README="apps/pricing/README.md"

# The README gets a revision line, so a repeated seed still has something to commit.
write_pricing_readme() {
  local file rev=0 line
  file="$(op_path "$PRICING_README")"
  if [[ -f "$file" ]]; then
    line="$(grep -E '^Notes revision: [0-9]+$' "$file" | tail -n1 || true)"
    [[ -z "$line" ]] || rev="${line##*: }"
  fi
  mkdir -p "$(dirname "$file")"
  printf '# pricing\n\nThe pricing service answers GET /price for checkout.\nIt has no state and no config of its own.\n\nNotes revision: %s\n' \
    "$((10#$rev + 1))" > "$file"
}

main() {
  local pr_sha docs_sha change_ref
  load_env
  require_context
  cluster_lock
  machine_init last-seed
  op_sync
  op_disarm
  op_sync

  change_ref="$(new_change_ref)"
  config_value_set "$CONFIG_ARMED"
  pr_sha="$(op_commit_push "$PR242_SUBJECT"$'\n\nDemo-Seed: pr-242' "$CONFIG_FILE")"
  beat "pushed: PR-242"
  emit_change_event "$pr_sha" config "$PR242_SUBJECT" "$change_ref"
  argo_refresh_and_wait checkout "$pr_sha"
  beat "synced"

  write_pricing_readme
  docs_sha="$(op_commit_push "$DOCS_SUBJECT" "$PRICING_README")"
  beat "pushed: docs"
  emit_change_event "$docs_sha" docs "$DOCS_SUBJECT" ""
  argo_refresh_and_wait pricing "$docs_sha"
  beat "synced"

  machine_line cause "$pr_sha"
  machine_line change_ref "$change_ref"
}

main "$@"
