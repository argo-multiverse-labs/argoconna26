#!/usr/bin/env bash
# Get a locally built image onto the kind nodes, and make sure a running pod uses it.
#
#   ensure-image.sh NAME TAG            tag NAME:latest-build as NAME:TAG (when it exists), then
#                                       load NAME:TAG unless every node already has it with the
#                                       same image ID. Prints "NAME:TAG present|loaded|reloaded".
#   ensure-image.sh --assert-running D  exit 1 unless every pod of Deployment D in $NS_AIOPS runs
#                                       the image the local Docker has under the Deployment's tag
#   ensure-image.sh --redeploy D        --assert-running, and when it fails delete the pods (not
#                                       'rollout restart', which Argo's selfHeal would fight), wait
#                                       for the rollout, then assert again
#
# Image ID. Docker with the containerd image store reports the image-index digest as .Id,
# while the nodes (containerd, via crictl) report the digest of the image config. The two never
# match, so the local side is read from the config digest in `docker save`'s manifest.json,
# which is the same number the node reports.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_env
require_context

# local_id REF -> sha256:<config digest>, or exit 1 when REF isn't in the local Docker
local_id() {
  docker image inspect "$1" >/dev/null 2>&1 || return 1
  local cfg
  cfg="$(docker save "$1" 2>/dev/null | tar -xOf - manifest.json | jq -r '.[0].Config // empty')" || return 1
  [[ -n "$cfg" ]] || return 1
  cfg="${cfg##*/}"       # blobs/sha256/<hex>  or  <hex>.json
  cfg="${cfg%.json}"
  printf 'sha256:%s\n' "${cfg#sha256:}"
}

nodes() { kind get nodes --name "$CLUSTER_NAME"; }

# node_id NODE REF -> the id the node's containerd has for REF; empty when it has none
node_id() {
  docker exec "$1" crictl inspecti -o json "$2" 2>/dev/null | jq -r '.status.id // empty' 2>/dev/null || true
}

ensure_one() {
  local name="$1" tag="$2" ref build_ref local_sum node have missing=0 differs=0
  ref="$name:$tag"
  build_ref="$name:latest-build"
  # A fresh build always wins over an older copy of the tag.
  if docker image inspect "$build_ref" >/dev/null 2>&1; then
    docker tag "$build_ref" "$ref"
  elif ! docker image inspect "$ref" >/dev/null 2>&1; then
    die "$ref not built: no $build_ref and no $ref in the local Docker (run: make images)"
  fi
  local_sum="$(local_id "$ref")" || die "cannot read the image ID of $ref"
  while read -r node; do
    [[ -n "$node" ]] || continue
    have="$(node_id "$node" "$ref")"
    if [[ -z "$have" ]]; then missing=1
    elif [[ "$have" != "$local_sum" ]]; then differs=1
    fi
  done < <(nodes)
  if (( ! missing && ! differs )); then
    printf '%s present\n' "$ref"
    return 0
  fi
  kind load docker-image "$ref" --name "$CLUSTER_NAME" >&2
  if (( differs )); then printf '%s reloaded\n' "$ref"; else printf '%s loaded\n' "$ref"; fi
}

# ---------------------------------------------------------------- running pods
DEPLOY_NS="${DEPLOY_NS:-$NS_AIOPS}"

# assert_running DEPLOY: every live pod must run the image the local Docker has under the
# Deployment's tag. Returns 1 with a message when they differ or can't be read.
assert_running() {
  local deploy="$1" dep ref selector want pods line pod node img have bad=0
  dep="$(k get deploy "$deploy" -n "$DEPLOY_NS" -o json 2>/dev/null)" \
    || { log_error "deployment $deploy not found in $DEPLOY_NS"; return 1; }
  ref="$(jq -r '.spec.template.spec.containers[0].image' <<<"$dep")"
  selector="$(jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$dep")"
  want="$(local_id "$ref")" || { log_error "$ref is not in the local Docker (run: make images)"; return 1; }
  pods="$(k get pods -n "$DEPLOY_NS" -l "$selector" -o json)"
  # skip terminating pods
  pods="$(jq -c '[.items[] | select(.metadata.deletionTimestamp == null)]' <<<"$pods")"
  if [[ "$(jq 'length' <<<"$pods")" == 0 ]]; then
    log_error "no running pods for $deploy"
    return 1
  fi
  while read -r line; do
    pod="$(jq -r '.metadata.name' <<<"$line")"
    node="$(jq -r '.spec.nodeName' <<<"$line")"
    img="$(jq -r '.status.containerStatuses[0].imageID // empty' <<<"$line")"
    if [[ "$img" == sha256:* ]]; then have="$img"; else have="$(node_id "$node" "$img")"; fi
    if [[ "$have" != "$want" ]]; then
      log_error "stale: pod $pod runs ${have:-an unknown image}, local $ref is $want"
      bad=1
    fi
  done < <(jq -c '.[]' <<<"$pods")
  (( bad == 0 )) || return 1
  log_info "$deploy runs the local $ref"
}

redeploy() {
  local deploy="$1" selector
  if assert_running "$deploy" 2>/dev/null; then
    log_info "$deploy already runs the local image"
    return 0
  fi
  selector="$(k get deploy "$deploy" -n "$DEPLOY_NS" -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')"
  log_info "$deploy runs a stale image: deleting its pods"
  k delete pod -n "$DEPLOY_NS" -l "$selector" --wait=false >&2
  k rollout status deploy/"$deploy" -n "$DEPLOY_NS" --timeout=180s >&2
  assert_running "$deploy"
}

case "${1:-}" in
  --assert-running) [[ $# -eq 2 ]] || die "usage: ensure-image.sh --assert-running DEPLOYMENT"; assert_running "$2" ;;
  --redeploy)       [[ $# -eq 2 ]] || die "usage: ensure-image.sh --redeploy DEPLOYMENT"; redeploy "$2" ;;
  -*|"")            die "usage: ensure-image.sh NAME TAG | --assert-running DEPLOYMENT | --redeploy DEPLOYMENT" ;;
  *)                [[ $# -eq 2 ]] || die "usage: ensure-image.sh NAME TAG"; ensure_one "$1" "$2" ;;
esac
