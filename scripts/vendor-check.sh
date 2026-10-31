#!/usr/bin/env bash
# Tool preflight: every required tool is present, and every tool pinned in
# versions.env is at exactly the pinned version. Exits 1 and names each offender.
# The caller puts TOOLS_BIN first on PATH (Makefile / load_env, P25).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a
# shellcheck disable=SC1091
. "$ROOT/versions.env"
set +a

fail=0
bad() { printf 'vendor: %s\n' "$*" >&2; fail=1; }

# first x.y.z in the output of a command
ver_of() { "$@" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }

present() { command -v "$1" >/dev/null 2>&1 || bad "missing tool: $1"; }

for t in docker kind kubectl helm argocd jq yq pv gh conftest bats shellcheck gitleaks asciinema agg uv envsubst flock curl git; do
  present "$t"
done
kubectl argo rollouts version >/dev/null 2>&1 || bad "missing tool: kubectl-argo-rollouts"

# check NAME WANT ACTUAL-COMMAND...
check() {
  local name="$1" want="$2"; shift 2
  command -v "${1}" >/dev/null 2>&1 || return 0   # already reported as missing
  local got; got="$(ver_of "$@")"
  want="${want#v}"
  if [[ "$got" != "$want" ]]; then
    bad "$name is ${got:+v}${got:-unknown}, pinned v${want} ($(command -v "$1"))"
  fi
}
check kind "$KIND_VERSION" kind version
check kubectl "$KUBECTL_VERSION" kubectl version --client
check kubectl-argo-rollouts "$ROLLOUTS_PLUGIN_VERSION" kubectl argo rollouts version
check argocd "$ARGOCD_VERSION" argocd version --client
check conftest "$CONFTEST_VERSION" conftest --version
check gitleaks "$GITLEAKS_VERSION" gitleaks version
check bats "$BATS_VERSION" bats --version
check asciinema "$ASCIINEMA_VERSION" asciinema --version
check agg "$AGG_VERSION" agg --version

if (( fail )); then exit 1; fi
echo "vendor: OK"
