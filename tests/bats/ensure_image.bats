#!/usr/bin/env bats
# Tests for scripts/ensure-image.sh (docker, kind and kubectl are stubs; nothing touches a cluster)
#
# Stub state lives in $DATA:
#   local_<ref>        the local image's config id          (exists = the image exists locally)
#   node_<node>_<ref>  the id a node reports for that ref   (exists = the node has the image)
#   pod_id             the imageID the running pod reports  (sha256:... or a repo digest)
#   images_<node>      that node's `crictl images -o json` output (repo digests live there)
#   log                every state-changing call, in order

load helpers

key() { printf '%s' "$1" | tr ':/@' '___'; }

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$FIXTURE"
  mkdir -p "$FIXTURE/.kube"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  DATA="$BATS_TEST_TMPDIR/data"
  mkdir -p "$DATA"
  : > "$DATA/log"
  export DATA
  # docker: tag / image inspect / save (a one-file tar holding manifest.json) / exec ... crictl inspecti
  make_stub "$STUBS" docker '
k() { printf "%s" "$1" | tr ":/@" "___"; }
case "$1" in
  tag)  echo "docker tag $2 $3" >> "$DATA/log"; cp "$DATA/local_$(k "$2")" "$DATA/local_$(k "$3")" ;;
  image) [ -f "$DATA/local_$(k "${@: -1}")" ] ;;
  save) id="$(cat "$DATA/local_$(k "$2")")" || exit 1
        d="$(mktemp -d)"
        printf "[{\"Config\":\"blobs/sha256/%s\",\"RepoTags\":[\"%s\"]}]" "${id#sha256:}" "$2" > "$d/manifest.json"
        tar -C "$d" -cf - manifest.json; rm -rf "$d" ;;
  exec) node="$2"; ref="${@: -1}"
        if [ "$4" = images ]; then cat "$DATA/images_$node"; exit 0; fi
        f="$DATA/node_${node}_$(k "$ref")"
        [ -f "$f" ] || { echo "no such image" >&2; exit 1; }
        printf "{\"status\":{\"id\":\"%s\"}}\n" "$(cat "$f")" ;;
  *) echo "docker stub: unexpected $*" >&2; exit 2 ;;
esac'
  make_stub "$STUBS" kind '
case "$1 $2" in
  "get nodes") echo argoconna26-control-plane; echo argoconna26-worker ;;
  "load docker-image")
    ref="$3"; echo "kind load $ref" >> "$DATA/log"
    for n in argoconna26-control-plane argoconna26-worker; do
      cp "$DATA/local_$(printf "%s" "$ref" | tr ":/@" "___")" "$DATA/node_${n}_$(printf "%s" "$ref" | tr ":/@" "___")"
    done ;;
  *) echo "kind stub: unexpected $*" >&2; exit 2 ;;
esac'
  # kubectl: current-context, the bridge Deployment and its pod, delete pod, rollout status
  make_stub "$STUBS" kubectl '
case "$*" in
  "config current-context") echo kind-argoconna26 ;;
  *"get deploy bridge"*) echo "{\"spec\":{\"selector\":{\"matchLabels\":{\"app\":\"bridge\"}},\"template\":{\"spec\":{\"containers\":[{\"image\":\"bridge:v0.1.0\"}]}}}}" ;;
  *"get pods"*)
    echo "kubectl get pods" >> "$DATA/log"
    uid="$(cat "$DATA/pod_uid" 2>/dev/null || echo uid-1)"
    if [ -s "$DATA/terminating" ]; then
      # right after the delete: the old pod is still listed, and its replacement has no imageID yet
      n="$(cat "$DATA/terminating")"; echo $((n - 1)) > "$DATA/terminating"; [ "$n" -gt 1 ] || : > "$DATA/terminating"
      echo "{\"items\":[{\"metadata\":{\"name\":\"bridge-1\",\"uid\":\"uid-1\"},\"spec\":{\"nodeName\":\"argoconna26-worker\"},\"status\":{\"containerStatuses\":[{\"imageID\":\"sha256:aaa\"}]}},{\"metadata\":{\"name\":\"bridge-2\",\"uid\":\"uid-2\"},\"spec\":{\"nodeName\":\"argoconna26-worker\"},\"status\":{}}]}"
    else
      echo "{\"items\":[{\"metadata\":{\"name\":\"bridge-1\",\"uid\":\"$uid\"},\"spec\":{\"nodeName\":\"argoconna26-worker\"},\"status\":{\"containerStatuses\":[{\"imageID\":\"$(cat "$DATA/pod_id")\"}]}}]}"
    fi ;;
  *"delete pod"*) echo "kubectl delete pod" >> "$DATA/log"
        # the replacement pod starts from whatever the node has now
        cat "$DATA/node_argoconna26-worker_bridge_v0.1.0" > "$DATA/pod_id"
        echo uid-2 > "$DATA/pod_uid"
        [ -z "${SLOW_DELETE:-}" ] || echo "$SLOW_DELETE" > "$DATA/terminating" ;;
  *"wait --for=condition=Ready"*) echo "kubectl wait ready" >> "$DATA/log" ;;
  *"rollout status"*) echo "kubectl rollout status" >> "$DATA/log" ;;
  *) echo "kubectl stub: unexpected $*" >&2; exit 2 ;;
esac'
  export PATH="$STUBS:$PATH" TOOLS_BIN="$STUBS"
}

set_local()  { printf '%s' "$2" > "$DATA/local_$(key "$1")"; }
set_node()   { printf '%s' "$3" > "$DATA/node_$1_$(key "$2")"; }
both_nodes() { set_node argoconna26-control-plane "$1" "$2"; set_node argoconna26-worker "$1" "$2"; }
ensure()     { run bash -c "cd '$FIXTURE' && '$REPO_ROOT/scripts/ensure-image.sh' $*"; }

@test "skips load when present with same image ID" {
  set_local pricing:v1.0.0 sha256:aaa
  both_nodes pricing:v1.0.0 sha256:aaa
  ensure pricing v1.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"pricing:v1.0.0 present"* ]]
  ! grep -q 'kind load' "$DATA/log"
}

@test "loads when absent" {
  set_local pricing:v1.0.0 sha256:aaa
  ensure pricing v1.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"pricing:v1.0.0 loaded"* ]]
  grep -q 'kind load pricing:v1.0.0' "$DATA/log"
}

@test "loads when only one node has it" {
  set_local pricing:v1.0.0 sha256:aaa
  set_node argoconna26-worker pricing:v1.0.0 sha256:aaa
  ensure pricing v1.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"pricing:v1.0.0 loaded"* ]]
}

@test "reloads when same tag but different image ID" {
  set_local pricing:v1.0.0 sha256:bbb
  both_nodes pricing:v1.0.0 sha256:aaa
  ensure pricing v1.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"pricing:v1.0.0 reloaded"* ]]
  grep -q 'kind load pricing:v1.0.0' "$DATA/log"
}

@test "tags latest-build as the requested tag, and a rebuilt latest-build wins" {
  set_local pricing:latest-build sha256:new
  set_local pricing:v1.0.0 sha256:old
  both_nodes pricing:v1.0.0 sha256:old
  ensure pricing v1.0.0
  [ "$status" -eq 0 ]
  grep -q 'docker tag pricing:latest-build pricing:v1.0.0' "$DATA/log"
  [[ "$output" == *"pricing:v1.0.0 reloaded"* ]]
}

@test "fails when the image exists neither as latest-build nor as the tag" {
  ensure pricing v1.0.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"not built"* ]]
}

@test "refuses a foreign kube context" {
  set_local pricing:v1.0.0 sha256:aaa
  make_stub "$STUBS" kubectl 'case "$*" in "config current-context") echo some-prod-cluster ;; esac'
  ensure pricing v1.0.0
  [ "$status" -eq 3 ]
  ! grep -q 'kind load' "$DATA/log"
}

@test "assert-running passes when the running pod has the local image" {
  set_local bridge:v0.1.0 sha256:aaa
  both_nodes bridge:v0.1.0 sha256:aaa
  printf 'sha256:aaa' > "$DATA/pod_id"
  ensure --assert-running bridge
  [ "$status" -eq 0 ]
}

@test "assert-running resolves a repo-digest imageID through the node's image list" {
  # crictl inspecti does not accept a repo digest; only the image list carries it
  set_local bridge:v0.1.0 sha256:aaa
  both_nodes bridge:v0.1.0 sha256:aaa
  printf 'docker.io/library/import-x@sha256:ddd' > "$DATA/pod_id"
  echo '{"images":[{"id":"sha256:zzz","repoDigests":["docker.io/library/other@sha256:eee"]},{"id":"sha256:aaa","repoDigests":["docker.io/library/import-x@sha256:ddd"]}]}' > "$DATA/images_argoconna26-worker"
  ensure --assert-running bridge
  [ "$status" -eq 0 ]
}

@test "assert-running fails when the pod's repo digest matches no image on the node" {
  set_local bridge:v0.1.0 sha256:aaa
  both_nodes bridge:v0.1.0 sha256:aaa
  printf 'docker.io/library/import-x@sha256:ddd' > "$DATA/pod_id"
  echo '{"images":[{"id":"sha256:zzz","repoDigests":["docker.io/library/other@sha256:eee"]}]}' > "$DATA/images_argoconna26-worker"
  ensure --assert-running bridge
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale"* ]]
}

@test "assert-running fails on a stale pod" {
  set_local bridge:v0.1.0 sha256:bbb
  both_nodes bridge:v0.1.0 sha256:bbb
  printf 'sha256:aaa' > "$DATA/pod_id"
  ensure --assert-running bridge
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale"* ]]
}

@test "redeploy deletes the pod when the running image ID differs even if the node already has the new image" {
  set_local bridge:v0.1.0 sha256:bbb
  both_nodes bridge:v0.1.0 sha256:bbb
  printf 'sha256:aaa' > "$DATA/pod_id"
  ensure --redeploy bridge
  [ "$status" -eq 0 ]
  grep -q 'kubectl delete pod' "$DATA/log"
  grep -q 'kubectl rollout status' "$DATA/log"
  [ "$(cat "$DATA/pod_id")" = sha256:bbb ]
}

@test "redeploy waits for the old pods to go and the new ones to be Ready before it checks" {
  set_local bridge:v0.1.0 sha256:bbb
  both_nodes bridge:v0.1.0 sha256:bbb
  printf 'sha256:aaa' > "$DATA/pod_id"
  export SLOW_DELETE=1      # the first listing after the delete still shows the old pod
  ensure --redeploy bridge
  [ "$status" -eq 0 ]
  order="$(grep -E 'delete pod|wait ready|rollout status' "$DATA/log" | tr '\n' ' ')"
  [ "$order" = "kubectl delete pod kubectl wait ready kubectl rollout status " ]
  # it listed the pods again after the delete until the old one was gone
  [ "$(sed -n '/delete pod/,/wait ready/p' "$DATA/log" | grep -c 'get pods')" -ge 2 ]
}

@test "redeploy leaves a current pod alone" {
  set_local bridge:v0.1.0 sha256:aaa
  both_nodes bridge:v0.1.0 sha256:aaa
  printf 'sha256:aaa' > "$DATA/pod_id"
  ensure --redeploy bridge
  [ "$status" -eq 0 ]
  ! grep -q 'kubectl delete pod' "$DATA/log"
}
