#!/usr/bin/env bash
# Fail when a tracked file hardcodes a version or name that versions.env / demo.env own.
#   scripts/check-consistency.sh [ROOT]     (ROOT defaults to the current checkout)
# Only tracked files are read (git ls-files), so untracked local files are never scanned.
# Prints "consistency: OK", or one "file:line: reason" per offence and exits 1.
# This grows each slice.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

set -a
# shellcheck disable=SC1091
. ./versions.env
# shellcheck disable=SC1091
. ./demo.env
set +a

# Files that legitimately contain the offences they test for, or own the values.
EXCLUDES=(':!versions.env' ':!demo.env' ':!tests/bats/fixtures' ':!tests/bats/consistency.bats' ':!scripts/check-consistency.sh')

offences=0
report() { printf '%s\n' "$1"; offences=$((offences + 1)); }

mapfile -t FILES < <(git ls-files -z -- . "${EXCLUDES[@]}" | tr '\0' '\n')
[[ ${#FILES[@]} -gt 0 ]] || { echo "consistency: OK"; exit 0; }

want_node_tag="${KIND_NODE_IMAGE#kindest/node:}"
want_node_tag="${want_node_tag%%@*}"
allowed_ns=" ${NS_ARGOCD} ${NS_ROLLOUTS} ${NS_MONITORING} ${NS_DEMO} ${NS_AIOPS} kube-system kube-public kube-node-lease default local-path-storage "

# 1. kindest/node image literals must match KIND_NODE_IMAGE
while IFS=: read -r file line text; do
  tag="$(grep -oE 'kindest/node:[A-Za-z0-9._-]+' <<<"$text" | head -1)"
  tag="${tag#kindest/node:}"
  [[ "$tag" == "$want_node_tag" ]] || report "$file:$line: kindest/node tag '$tag' differs from versions.env ($want_node_tag)"
done < <(git grep -nI -E 'kindest/node:[A-Za-z0-9._-]+' -- "${FILES[@]}" 2>/dev/null || true)

# 2. a helm chart --version must come from versions.env, never a literal
while IFS=: read -r file line text; do
  report "$file:$line: hardcoded chart --version (use the pin from versions.env): ${text//[[:space:]]/ }"
done < <(git grep -nI -E -e '--version[ =]+v?[0-9]+\.[0-9]+' -- "${FILES[@]}" 2>/dev/null || true)

# 3. namespace literals in kubectl/helm calls and manifests must be one of the known namespaces
check_ns() { # file line value
  local v="$3"
  [[ -z "$v" || "$v" == \$* || "$v" == \{\{* || "$v" == \"\$* || "$v" == \'* ]] && return 0
  v="${v//\"/}"
  [[ "$allowed_ns" == *" $v "* ]] || report "$1:$2: unknown namespace literal '$v'"
}
while IFS=: read -r file line text; do
  # conftest's --namespace names a Rego package, not a Kubernetes namespace
  text="${text%%conftest *}"
  if [[ "$text" =~ ([[:space:]]|^)(-n|--namespace)[[:space:]=]+([^[:space:]]+) ]]; then
    check_ns "$file" "$line" "${BASH_REMATCH[3]}"
  fi
done < <(git grep -nI -E '(kubectl|helm|(^|[[:space:];|&(])k )[^#]*[[:space:]](-n|--namespace)[[:space:]=]+[^[:space:]]+' -- "${FILES[@]}" 2>/dev/null || true)
while IFS=: read -r file line text; do
  if [[ "$text" =~ ^[[:space:]-]*namespace:[[:space:]]*([^[:space:]#]+) ]]; then
    check_ns "$file" "$line" "${BASH_REMATCH[1]}"
  fi
done < <(git grep -nI -E '^[[:space:]-]*namespace:[[:space:]]*[^[:space:]#]+' -- "${FILES[@]}" 2>/dev/null \
  | grep -E '^[^:]+\.(ya?ml|md|tpl|j2):' || true)  # manifests only: a Python field 'namespace: str' is not one

# 4. a kind context literal must be the demo's
while IFS=: read -r file line text; do
  ctx="$(grep -oE 'kind-[A-Za-z0-9._-]+' <<<"$text" | head -1)"
  [[ "$ctx" == "$CLUSTER_CONTEXT" ]] || report "$file:$line: context '$ctx' is not $CLUSTER_CONTEXT"
done < <(git grep -nI -E -e '--context[ =]+kind-[A-Za-z0-9._-]+' -- "${FILES[@]}" 2>/dev/null || true)

# 5. image pins in Dockerfiles come from versions.env as build args (PYTHON_IMAGE,
#    UV_IMAGE): no literal FROM or COPY --from image, no default on an ARG that names
#    an image, and no unpinned `pip install uv`.
while IFS= read -r file; do
  stages=" "
  while IFS= read -r st; do stages+="$st "; done < <(grep -ioE '^[[:space:]]*FROM[[:space:]].*[[:space:]]AS[[:space:]]+[A-Za-z0-9._-]+' "$file" | awk '{print tolower($NF)}')
  n=0
  while IFS= read -r text || [[ -n "$text" ]]; do
    n=$((n + 1))
    if [[ "$text" =~ ^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+(--platform=[^[:space:]]+[[:space:]]+)?([^[:space:]]+) ]]; then
      img="${BASH_REMATCH[2]}"
      [[ "$img" == \$* || "${img,,}" == scratch || "$stages" == *" ${img,,} "* ]] \
        || report "$file:$n: literal base image '$img' (use a build arg from versions.env)"
    fi
    if [[ "$text" =~ --from=([^[:space:],]+) ]]; then
      img="${BASH_REMATCH[1]}"
      [[ "$img" == \$* || "$stages" == *" ${img,,} "* || "$img" =~ ^[0-9]+$ ]] \
        || report "$file:$n: literal --from image '$img' (use a build arg from versions.env)"
    fi
    if [[ "$text" =~ ^[[:space:]]*ARG[[:space:]]+([A-Za-z0-9_]*IMAGE[A-Za-z0-9_]*)= ]]; then
      report "$file:$n: ARG ${BASH_REMATCH[1]} has a default (versions.env owns it)"
    fi
    if [[ "$text" =~ pip[[:space:]]+install[[:space:]]+([^;&|]*[[:space:]])?uv([[:space:]]|$|[^A-Za-z0-9_=.-]) ]]; then
      report "$file:$n: unpinned 'pip install uv' (use UV_IMAGE from versions.env)"
    fi
  done < "$file"
done < <(printf '%s\n' "${FILES[@]}" | grep -E '(^|/)(Dockerfile|Containerfile)[^/]*$' || true)

# 6. cdevents-sim (O4): the Deployment's BRIDGE_EVENT_SOURCE and the kustomize image tag
#    must equal demo.env's BRIDGE_EVENT_SOURCE and SIM_TAG. The sim refuses to start without
#    the source, and a mismatch would let the bridge's events into /timeline (P16).
if [[ -n "${BRIDGE_EVENT_SOURCE:-}" && -f cdevents-sim/deploy/deployment.yaml ]]; then
  got="$(awk '/name: BRIDGE_EVENT_SOURCE/ {getline; sub(/^[[:space:]]*value:[[:space:]]*/, ""); gsub(/["\047]/, ""); print; exit}' cdevents-sim/deploy/deployment.yaml)"
  [[ "$got" == "$BRIDGE_EVENT_SOURCE" ]] \
    || report "cdevents-sim/deploy/deployment.yaml: BRIDGE_EVENT_SOURCE '$got' differs from demo.env ($BRIDGE_EVENT_SOURCE)"
fi
if [[ -n "${SIM_TAG:-}" && -f cdevents-sim/deploy/kustomization.yaml ]]; then
  got="$(awk '/name: cdevents-sim/ {getline; sub(/^[[:space:]]*newTag:[[:space:]]*/, ""); gsub(/["\047]/, ""); print; exit}' cdevents-sim/deploy/kustomization.yaml)"
  [[ "$got" == "$SIM_TAG" ]] \
    || report "cdevents-sim/deploy/kustomization.yaml: newTag '$got' differs from demo.env SIM_TAG ($SIM_TAG)"
fi

# 6b. bridge: every env value its Deployment takes from demo.env, and the kustomize image
#     tag (BRIDGE_TAG). A BRIDGE_EVENT_SOURCE that differs from the sim's would let the
#     bridge's own standard-type events reach HolmesGPT through /timeline (P16).
# env_value FILE NAME : the value of env NAME, in the `- {name: N, value: V}` or the
# two-line `- name: N` / `value: V` form, quotes removed; empty when absent.
env_value() {
  awk -v n="$2" '
    function clean(s) { gsub(/["\047]/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    $0 ~ ("name:[[:space:]]*" n "[[:space:]]*,") && /value:/ {
      s = $0; sub(/.*value:[[:space:]]*/, "", s); sub(/[[:space:]]*}[[:space:]]*$/, "", s); print clean(s); exit
    }
    $0 ~ ("name:[[:space:]]*" n "[[:space:]]*$") {
      if ((getline) > 0 && $0 ~ /^[[:space:]]*value:/) { sub(/^[[:space:]]*value:[[:space:]]*/, ""); print clean($0) }
      exit
    }' "$1"
}
if [[ -f bridge/deploy/deployment.yaml ]]; then
  declare -A bridge_want=(
    [REPO_SLUG]="${REPO_SLUG:-}" [TRACKED_BRANCH]="${TRACKED_BRANCH:-}" [HOLMES_URL]="${HOLMES_URL:-}"
    [HOLMES_TIMEOUT_S]="${HOLMES_TIMEOUT_S:-}" [STAGE_COLS]="${STAGE_COLS:-}"
    [CDEVENTS_URL]="${SIM_URL:+${SIM_URL}/events}" [BRIDGE_EVENT_SOURCE]="${BRIDGE_EVENT_SOURCE:-}"
    [ARGO_UI_URL]="${ARGOCD_HOST_URL:-}" [ROLLOUT_FILE]="${ROLLOUT_FILE:-}"
    [KUSTOMIZATION_FILE]="${KUSTOMIZATION_FILE:-}" [CHECKOUT_CVE_TAG]="${CHECKOUT_CVE_TAG:-}"
    [BOT_LOGIN]="${BOT_LOGIN:-}"
  )
  for name in REPO_SLUG TRACKED_BRANCH HOLMES_URL HOLMES_TIMEOUT_S STAGE_COLS CDEVENTS_URL BRIDGE_EVENT_SOURCE ARGO_UI_URL \
      ROLLOUT_FILE KUSTOMIZATION_FILE CHECKOUT_CVE_TAG BOT_LOGIN; do
    want="${bridge_want[$name]}"
    [[ -n "$want" ]] || continue
    got="$(env_value bridge/deploy/deployment.yaml "$name")"
    [[ "$got" == "$want" ]] \
      || report "bridge/deploy/deployment.yaml: $name '${got:-<missing>}' differs from demo.env ($want)"
  done
fi
if [[ -n "${BRIDGE_TAG:-}" && -f bridge/deploy/kustomization.yaml ]]; then
  got="$(awk '/name: bridge[[:space:]]*$/ {getline; sub(/^[[:space:]]*newTag:[[:space:]]*/, ""); gsub(/["\047]/, ""); print; exit}' bridge/deploy/kustomization.yaml)"
  [[ "$got" == "$BRIDGE_TAG" ]] \
    || report "bridge/deploy/kustomization.yaml: newTag '$got' differs from demo.env BRIDGE_TAG ($BRIDGE_TAG)"
fi

# 7. LiteLLM: the chart values' image tag and the Postgres StatefulSet image must equal the pins.
if [[ -n "${LITELLM_IMAGE_TAG:-}" && -f platform/litellm/values.yaml ]]; then
  got="$(awk '/^image:/ {f=1; next} f && /^[[:space:]]+tag:/ {sub(/^[[:space:]]*tag:[[:space:]]*/, ""); gsub(/["\047]/, ""); print; exit}' platform/litellm/values.yaml)"
  [[ "$got" == "$LITELLM_IMAGE_TAG" ]] \
    || report "platform/litellm/values.yaml: image tag '$got' differs from versions.env LITELLM_IMAGE_TAG ($LITELLM_IMAGE_TAG)"
fi
if [[ -n "${POSTGRES_IMAGE:-}" && -f platform/litellm/postgres.yaml ]]; then
  got="$(awk '/^[[:space:]]*image:/ {sub(/^[[:space:]]*image:[[:space:]]*/, ""); gsub(/["\047]/, ""); print; exit}' platform/litellm/postgres.yaml)"
  [[ "$got" == "$POSTGRES_IMAGE" ]] \
    || report "platform/litellm/postgres.yaml: image '$got' differs from versions.env POSTGRES_IMAGE ($POSTGRES_IMAGE)"
fi

# 8. HolmesGPT: the chart values' image must be the pinned version, and HOLMES_URL must name the
#    release's Service (<release>-holmes) in the aiops namespace.
if [[ -n "${HOLMES_CHART_VERSION:-}" && -f platform/holmes/values.yaml ]]; then
  got="$(awk '/^image:/ {sub(/^image:[[:space:]]*/, ""); gsub(/["\047]/, ""); print; exit}' platform/holmes/values.yaml)"
  [[ "$got" == "holmes:${HOLMES_CHART_VERSION}" ]] \
    || report "platform/holmes/values.yaml: image '$got' differs from versions.env HOLMES_CHART_VERSION (holmes:$HOLMES_CHART_VERSION)"
fi
if [[ -n "${HOLMES_URL:-}" && -n "${HOLMES_RELEASE:-}" && -n "${NS_AIOPS:-}" ]]; then
  [[ "$HOLMES_URL" == "http://${HOLMES_RELEASE}-holmes.${NS_AIOPS}.svc" ]] \
    || report "demo.env: HOLMES_URL '$HOLMES_URL' is not the Service http://${HOLMES_RELEASE}-holmes.${NS_AIOPS}.svc"
fi

if (( offences > 0 )); then
  echo "consistency: $offences offence(s)" >&2
  exit 1
fi
echo "consistency: OK"
