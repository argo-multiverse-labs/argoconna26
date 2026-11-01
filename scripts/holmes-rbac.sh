#!/usr/bin/env bash
# HolmesGPT is read-only. Two proofs (Task 3.12 Step 2, O7):
#   scripts/holmes-rbac.sh render          the chart's rendered ClusterRole (YAML) on stdout
#   scripts/holmes-rbac.sh check [FILE]    FILE (default: render) has only get/list/watch, no secrets, no "*"
#   scripts/holmes-rbac.sh live            kubectl auth can-i against the running cluster
#   scripts/holmes-rbac.sh allowlist       the /timeline and /incidents allow-list, in the pinned image
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

HOLMES_SA="${HOLMES_SA:-holmes-holmes-service-account}"

# render_chart : the whole chart as YAML
render_chart() {
  h template "${HOLMES_RELEASE:-holmes}" robusta/holmes --version "$HOLMES_CHART_VERSION" -n "$NS_AIOPS" \
    -f "$COMMON_ROOT/platform/holmes/values.yaml"
}

# role_only : keep the Role/ClusterRole documents
role_only() { yq 'select(.kind == "ClusterRole" or .kind == "Role")'; }

# check_rules FILE : prints one line per offence; returns 1 when there is any
check_rules() {
  local file="$1" out rc=0
  out="$(yq -o=json 'select(.kind == "ClusterRole" or .kind == "Role")' "$file" | jq -s -r '
    [ .[] | .metadata.name as $role | .rules[]?
      | . as $r
      | ($r.verbs[]? | select(. != "get" and . != "list" and . != "watch") | "\($role): verb \(.) is not read-only"),
        ($r.resources[]? | select(. == "*" or test("^secrets($|/)")) | "\($role): resource \(.) is not allowed"),
        ($r.resources[]? | select(test("/(exec|attach|portforward|proxy|token|ephemeralcontainers)$")) | "\($role): subresource \(.) is not allowed"),
        ($r.apiGroups[]? | select(. == "*") | "\($role): apiGroup * is not allowed")
    ] | .[]')"
  if [[ -n "$out" ]]; then printf '%s\n' "$out"; rc=1; fi
  if ! yq 'select(.kind == "ClusterRole" or .kind == "Role") | .kind' "$file" | grep -q .; then
    echo "no Role or ClusterRole in $file"; rc=1
  fi
  return "$rc"
}

cmd_check() {
  local file="${1:-}" tmp="" rc=0 verbs
  if [[ -z "$file" ]]; then tmp="$(mktemp)"; render_chart > "$tmp"; file="$tmp"; fi
  verbs="$(yq 'select(.kind == "ClusterRole" or .kind == "Role") | .rules[].verbs[]' "$file" | sort -u | tr '\n' ' ')"
  check_rules "$file" || rc=1
  [[ -z "$tmp" ]] || rm -f "$tmp"
  if (( rc == 0 )); then
    log_info "holmes rbac: verbs [${verbs% }]; no secrets, no wildcard resources or groups, no exec/proxy/token subresources"
  else
    log_error "holmes rbac: the rendered role is not read-only"
  fi
  return "$rc"
}

# can_i EXPECTED ARGS... : kubectl auth can-i as the Holmes ServiceAccount
can_i() {
  local want="$1" got; shift
  got="$(k auth can-i "$@" --as="system:serviceaccount:${NS_AIOPS}:${HOLMES_SA}" 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then log_info "can-i $* -> $got"; return 0; fi
  log_error "can-i $* -> '$got' (want $want)"; return 1
}

cmd_live() {
  local rc=0
  # The Secrets that matter: the bridge's GitHub App key and webhook token, the Argo CD
  # notifications secret (the bridge bearer) and the LiteLLM master key.
  can_i no get secret/bridge-secrets -n "$NS_AIOPS" || rc=1
  can_i no get secret/argocd-notifications-secret -n "$NS_ARGOCD" || rc=1
  can_i no get secret/litellm-masterkey -n "$NS_AIOPS" || rc=1
  can_i no list secrets --all-namespaces || rc=1
  can_i no create pods -n "$NS_DEMO" || rc=1
  can_i yes get pods -n "$NS_DEMO" || rc=1
  can_i yes get rollouts.argoproj.io -n "$NS_DEMO" || rc=1
  return "$rc"
}

cmd_allowlist() {
  local tmp rc=0
  tmp="$(mktemp)"
  render_chart | yq 'select(.kind == "ConfigMap" and .metadata.name == "custom-toolsets-configmap") | .data."custom_toolset.yaml"' \
    | yq -o=json '.toolsets."cdevents-timeline".config' > "$tmp"
  docker run --rm -i --entrypoint python3 -v "$COMMON_ROOT/tests/holmes/allowlist.py:/t/allowlist.py:ro" \
    "robustadev/holmes:$HOLMES_CHART_VERSION" /t/allowlist.py < "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

main() {
  local cmd="${1:-}"; shift || true
  load_env
  case "$cmd" in
    render)    require_context; render_chart | role_only ;;
    check)     require_context; cmd_check "$@" ;;
    live)      require_context; cmd_live ;;
    allowlist) cmd_allowlist ;;
    *) die "usage: holmes-rbac.sh render|check [FILE]|live|allowlist" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
