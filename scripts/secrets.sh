#!/usr/bin/env bash
# Load .env into cluster Secrets, idempotently. Secret values never reach stdout, stderr or kubectl args.
#   scripts/secrets.sh base|late|all
# base: needs no running service (grafana-admin, litellm, bridge, argocd-notifications)
# late: needs running services (holmes, cdevents-grafana); stubbed until slice 3.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_ensure_ns() { # NS (created only when missing, so Helm-owned namespaces are left alone)
  k get namespace "$1" >/dev/null 2>&1 || k create namespace "$1" --dry-run=client -o yaml | k apply -f - >/dev/null
}

# _have KEY... : true when every key is set and non-empty in the environment
_have() {
  local v
  for v in "$@"; do [[ -n "${!v:-}" ]] || return 1; done
}

# Entries are written one per file into a private (0700) temp dir and passed with
# --from-file=<dir>, so values never appear in process arguments and multi-line values
# (a PEM key) work. `kubectl create secret` cannot mix --from-env-file with --from-file.
SECRET_DIR=""

_new_secret_dir() {
  _cleanup_secret_dir
  SECRET_DIR="$(mktemp -d)"
  chmod 700 "$SECRET_DIR"
}

_put() { printf '%s' "$2" > "$SECRET_DIR/$1"; } # KEY VALUE (printf is a builtin: no argv exposure)

_cleanup_secret_dir() { [[ -z "${SECRET_DIR:-}" ]] || rm -rf "$SECRET_DIR"; SECRET_DIR=""; }

LAST_APPLIED=kubectl.kubernetes.io/last-applied-configuration

# _apply_secret NS NAME [--from-file=k=path ...]
# Server-side apply: unlike client-side apply it writes no last-applied-configuration
# annotation, which would hold a second copy of every value in object metadata. An
# unchanged Secret is a no-op (same UID and resourceVersion), so build-all stays idempotent.
_apply_secret() {
  local ns="$1" name="$2"; shift 2
  _ensure_ns "$ns"
  k create secret generic "$name" -n "$ns" --from-file="$SECRET_DIR" "$@" \
    --dry-run=client -o yaml \
    | k apply --server-side --field-manager=secrets-sh --force-conflicts -f - >/dev/null
  # A Secret first written by an older client-side apply still carries the annotation.
  # (Checked with jq -e, so the annotation's value is never read into the shell.)
  if k get secret "$name" -n "$ns" -o json 2>/dev/null \
       | jq -e --arg a "$LAST_APPLIED" '.metadata.annotations[$a] != null' >/dev/null; then
    k annotate secret "$name" -n "$ns" "${LAST_APPLIED}-" >/dev/null
    log_info "secret: $ns/$name (removed the old last-applied annotation)"
  fi
  log_info "secret: $ns/$name"
  _cleanup_secret_dir
}

secret_grafana_admin() {
  if ! _have GRAFANA_ADMIN_PASSWORD; then
    log_warn "skipped: grafana-admin (GRAFANA_ADMIN_PASSWORD missing in .env)"; return 0
  fi
  _new_secret_dir
  _put admin-user admin
  _put admin-password "$GRAFANA_ADMIN_PASSWORD"
  _apply_secret "$NS_MONITORING" grafana-admin
}

secret_litellm() {
  if ! _have LITELLM_MASTER_KEY LITELLM_SALT_KEY LITELLM_DB_PASSWORD; then
    log_warn "skipped: litellm (LITELLM_MASTER_KEY, LITELLM_SALT_KEY or LITELLM_DB_PASSWORD missing in .env)"; return 0
  fi
  _new_secret_dir; _put masterkey "$LITELLM_MASTER_KEY"
  _apply_secret "$NS_AIOPS" litellm-masterkey
  _new_secret_dir; _put username litellm; _put password "$LITELLM_DB_PASSWORD"
  _apply_secret "$NS_AIOPS" litellm-db
  if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" ]]; then
    log_warn "litellm-env has no provider key (ANTHROPIC_API_KEY or OPENAI_API_KEY missing in .env); model calls will fail"
  fi
  _new_secret_dir
  _put LITELLM_SALT_KEY "$LITELLM_SALT_KEY"
  [[ -z "${ANTHROPIC_API_KEY:-}" ]] || _put ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY"
  [[ -z "${OPENAI_API_KEY:-}" ]] || _put OPENAI_API_KEY "$OPENAI_API_KEY"
  _apply_secret "$NS_AIOPS" litellm-env
}

secret_holmes() {
  log_info "skipped: holmes (added in slice 3)"
}

secret_cdevents_grafana() {
  log_info "skipped: cdevents-grafana (added in slice 3)"
}

secret_bridge() {
  local keyfile="" root real
  if ! _have BRIDGE_WEBHOOK_TOKEN; then
    log_warn "skipped: bridge (BRIDGE_WEBHOOK_TOKEN missing in .env)"; return 0
  fi
  if [[ -n "${GITHUB_APP_KEY_PATH:-}" ]]; then
    root="$(main_root)"
    real="$(realpath -m "$GITHUB_APP_KEY_PATH")"
    case "$real/" in
      "$root"/*|"$COMMON_ROOT"/*) die "GITHUB_APP_KEY_PATH must live outside the repo" ;;
    esac
    [[ -r "$real" ]] || die "GITHUB_APP_KEY_PATH is not a readable file"
    keyfile="$real"
  fi
  _new_secret_dir
  _put webhook-token "$BRIDGE_WEBHOOK_TOKEN"
  [[ -z "${HOLMES_API_KEY:-}" ]] || _put holmes-api-key "$HOLMES_API_KEY"
  [[ -z "${GITHUB_APP_ID:-}" ]] || _put github-app-id "$GITHUB_APP_ID"
  [[ -z "${GITHUB_INSTALLATION_ID:-}" ]] || _put github-installation-id "$GITHUB_INSTALLATION_ID"
  if [[ -n "$keyfile" ]]; then
    _apply_secret "$NS_AIOPS" bridge-secrets "--from-file=github-app-key=$keyfile"
  else
    log_warn "bridge: no GitHub App key yet (GITHUB_APP_KEY_PATH unset); the bridge Secret has no App credentials"
    _apply_secret "$NS_AIOPS" bridge-secrets
  fi
}

secret_argocd_notifications() {
  if ! _have BRIDGE_WEBHOOK_TOKEN; then
    log_warn "skipped: argocd-notifications-secret (BRIDGE_WEBHOOK_TOKEN missing in .env)"; return 0
  fi
  _new_secret_dir; _put bridge-token "$BRIDGE_WEBHOOK_TOKEN"
  _apply_secret "$NS_ARGOCD" argocd-notifications-secret
}

secrets_base() {
  secret_grafana_admin
  secret_litellm
  secret_bridge
  secret_argocd_notifications
}

secrets_late() {
  secret_holmes
  secret_cdevents_grafana
}

main() {
  local what="${1:-base}"
  load_env
  trap _cleanup_secret_dir EXIT
  cluster_lock
  require_context
  case "$what" in
    base) secrets_base ;;
    late) secrets_late ;;
    all)  secrets_base; secrets_late ;;
    *) die "usage: secrets.sh base|late|all" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
