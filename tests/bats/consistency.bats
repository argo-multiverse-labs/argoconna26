#!/usr/bin/env bats
# Tests for scripts/check-consistency.sh

load helpers

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  cp -r "$REPO_ROOT/tests/bats/fixtures/consistency/." "$WORK/"
  git -C "$WORK" init -q -b main
  git -C "$WORK" config user.email t@example.invalid
  git -C "$WORK" config user.name t
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m fixture
}

plant() { # FILE LINE : append an offence to a tracked file and commit it
  printf '%s\n' "$2" >> "$WORK/$1"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m plant
}

@test "clean fixture prints consistency: OK" {
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "consistency: OK" ]
}

@test "flags a different kindest/node tag" {
  plant cluster.sh '# image: kindest/node:v1.32.11'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cluster.sh:5:"* ]]
}

@test "flags a hardcoded chart --version" {
  plant Makefile $'\thelm upgrade --install kps prom/kube-prometheus-stack --version 80.1.0'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Makefile:4:"* ]]
}

@test "FROM scratch is not a literal base image" {
  mkdir -p "$WORK/bridge"
  printf 'ARG PYTHON_IMAGE\nFROM $PYTHON_IMAGE AS build\nFROM scratch\nCOPY --from=build /x /x\n' > "$WORK/bridge/Dockerfile"
  git -C "$WORK" add -A; git -C "$WORK" commit -q -m df
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "consistency: OK" ]
}

@test "flags an unknown namespace literal" {
  plant cluster.sh 'kubectl get pods -n observability'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cluster.sh:5:"* ]]
  [[ "$output" == *observability* ]]
}

@test "flags an unknown namespace in a manifest" {
  plant deploy.yaml '  namespace: scratch'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"deploy.yaml:4:"* ]]
}

@test "flags a foreign kind context" {
  plant cluster.sh 'kubectl --context kind-other get nodes'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cluster.sh:5:"* ]]
}

@test "untracked files are not scanned" {
  printf 'kubectl get pods -n observability\n' > "$WORK/untracked.sh"
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "consistency: OK" ]
}

# ------------------------------------------------------------ image pins in Dockerfiles
plant_file() { # FILE CONTENT : add a new tracked file
  mkdir -p "$(dirname "$WORK/$1")"
  printf '%s\n' "$2" > "$WORK/$1"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m plant
}

@test "a Dockerfile built only from build args passes" {
  plant_file app/Dockerfile $'ARG PYTHON_IMAGE\nARG UV_IMAGE\nFROM ${UV_IMAGE} AS uv\nFROM ${PYTHON_IMAGE}\nCOPY --from=uv /uv /usr/local/bin/uv\nRUN --mount=from=uv,source=/uv,target=/usr/local/bin/uv uv export -o /tmp/r.txt'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "consistency: OK" ]
}

@test "flags a literal FROM image" {
  plant_file app/Dockerfile $'FROM python:3.13-slim\nCMD ["x"]'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"app/Dockerfile:1:"* ]]
}

@test "flags a default on an image build arg" {
  plant_file app/Dockerfile $'ARG PYTHON_IMAGE=python:3.13-slim\nFROM ${PYTHON_IMAGE}'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"app/Dockerfile:1:"* ]]
}

@test "flags a literal COPY --from image" {
  plant_file app/Dockerfile $'ARG PYTHON_IMAGE\nFROM ${PYTHON_IMAGE}\nCOPY --from=ghcr.io/astral-sh/uv:0.13.6 /uv /usr/local/bin/uv'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"app/Dockerfile:3:"* ]]
}

@test "flags an unpinned pip install uv" {
  plant_file app/Dockerfile $'ARG PYTHON_IMAGE\nFROM ${PYTHON_IMAGE}\nRUN pip install uv && uv export'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"app/Dockerfile:3:"* ]]
}

@test "pip uninstall uv after another install is not flagged" {
  plant_file app/Dockerfile $'ARG PYTHON_IMAGE\nFROM ${PYTHON_IMAGE}\nRUN pip install -r /tmp/r.txt && pip uninstall -y uv'
  run "$REPO_ROOT/scripts/check-consistency.sh" "$WORK"
  [ "$status" -eq 0 ]
}
