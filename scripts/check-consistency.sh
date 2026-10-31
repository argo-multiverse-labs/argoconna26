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
  if [[ "$text" =~ ([[:space:]]|^)(-n|--namespace)[[:space:]=]+([^[:space:]]+) ]]; then
    check_ns "$file" "$line" "${BASH_REMATCH[3]}"
  fi
done < <(git grep -nI -E '(kubectl|helm|(^|[[:space:];|&(])k )[^#]*[[:space:]](-n|--namespace)[[:space:]=]+[^[:space:]]+' -- "${FILES[@]}" 2>/dev/null || true)
while IFS=: read -r file line text; do
  if [[ "$text" =~ ^[[:space:]-]*namespace:[[:space:]]*([^[:space:]#]+) ]]; then
    check_ns "$file" "$line" "${BASH_REMATCH[1]}"
  fi
done < <(git grep -nI -E '^[[:space:]-]*namespace:[[:space:]]*[^[:space:]#]+' -- "${FILES[@]}" 2>/dev/null || true)

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
      [[ "$img" == \$* || "$stages" == *" ${img,,} "* ]] \
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

if (( offences > 0 )); then
  echo "consistency: $offences offence(s)" >&2
  exit 1
fi
echo "consistency: OK"
