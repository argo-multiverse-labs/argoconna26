#!/usr/bin/env bats
# Tests for scripts/secrets.sh (kubectl is a recording stub; nothing touches a cluster)

load helpers

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$FIXTURE"
  mkdir -p "$FIXTURE/.kube"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  CALLS="$BATS_TEST_TMPDIR/kubectl.calls"
  : > "$CALLS"
  # kubectl stub: records args (and the staging dir mode for 'create secret'),
  # prints a fake manifest for 'create ... -o yaml', and accepts 'apply'.
  make_stub "$STUBS" kubectl 'echo "ARGS: $*" >> "'"$CALLS"'"
    case "$*" in
      "config current-context") echo kind-argoconna26 ;;
      *"create secret generic"*)
        case "$*" in *--from-env-file=*) echo "error: from-env-file cannot be combined with from-file" >&2; exit 1;; esac
        d="$(grep -o -- "--from-file=/[^ ]*" <<<"$*" | cut -d= -f2-)"
        echo "DIR-MODE: $(stat -c %a "$d")" >> "'"$CALLS"'"
        echo "DIR-FILES: $(ls "$d" | tr "\n" " ")" >> "'"$CALLS"'"
        echo "apiVersion: v1"; echo "kind: Secret" ;;
      *"create namespace"*) echo "apiVersion: v1"; echo "kind: Namespace" ;;
      *"apply -f -"*) cat > /dev/null; echo "applied" ;;
    esac'
  export PATH="$STUBS:$PATH" TOOLS_BIN="$STUBS"
  # fake values, held in neutrally named variables so secret scanners see no credential-shaped lines
  v1=grafana-s3cret-pw v2=master-s3cret v3=salt-s3cret v4=db-s3cret v5=sk-ant-s3cret v6=bridge-s3cret v7=holmes-s3cret
  {
    echo "GRAFANA_ADMIN_PASSWORD=$v1"
    echo "LITELLM_MASTER_KEY=$v2"
    echo "LITELLM_SALT_KEY=$v3"
    echo "LITELLM_DB_PASSWORD=$v4"
    echo "ANTHROPIC_API_KEY=$v5"
    echo "BRIDGE_WEBHOOK_TOKEN=$v6"
    echo "HOLMES_API_KEY=$v7"
  } > "$FIXTURE/.env"
  chmod 600 "$FIXTURE/.env"
}

run_secrets() { ( cd "$FIXTURE" && "$REPO_ROOT/scripts/secrets.sh" "$@" ); }

@test "secrets is idempotent" {
  run run_secrets base
  [ "$status" -eq 0 ]
  first="$(grep -c 'apply -f -' "$CALLS")"
  run run_secrets base
  [ "$status" -eq 0 ]
  second="$(grep -c 'apply -f -' "$CALLS")"
  [ "$first" -gt 0 ]
  [ "$second" -eq $((first * 2)) ]
  # every secret goes through create --dry-run | apply, never a bare create
  ! grep -E 'ARGS:.* create secret' "$CALLS" | grep -v -- '--dry-run=client'
}

@test "missing key skips with warning, exit 0" {
  : > "$FIXTURE/.env"
  run run_secrets base
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped: grafana-admin"* ]]
  ! grep -q 'create secret' "$CALLS"
}

@test "no secret value appears in output" {
  run run_secrets all
  [ "$status" -eq 0 ]
  for v in grafana-s3cret-pw master-s3cret salt-s3cret db-s3cret sk-ant-s3cret bridge-s3cret holmes-s3cret; do
    [[ "$output" != *"$v"* ]]
  done
}

@test "no secret value appears in kubectl arguments, and secret staging dirs are mode 700" {
  run run_secrets base
  [ "$status" -eq 0 ]
  for v in grafana-s3cret-pw master-s3cret salt-s3cret db-s3cret sk-ant-s3cret bridge-s3cret holmes-s3cret; do
    ! grep -q "$v" "$CALLS"
  done
  grep -q 'DIR-MODE: 700' "$CALLS"
  ! grep 'DIR-MODE' "$CALLS" | grep -vq 'DIR-MODE: 700'
}

@test "key file path outside repo required" {
  echo "-----BEGIN KEY-----" > "$FIXTURE/agent.pem"
  echo "GITHUB_APP_KEY_PATH=$FIXTURE/agent.pem" >> "$FIXTURE/.env"
  run run_secrets base
  [ "$status" -ne 0 ]
  [[ "$output" == *"must live outside the repo"* ]]
}

@test "a key file outside the repo is accepted" {
  echo "-----BEGIN KEY-----" > "$BATS_TEST_TMPDIR/agent.pem"
  echo "GITHUB_APP_KEY_PATH=$BATS_TEST_TMPDIR/agent.pem" >> "$FIXTURE/.env"
  run run_secrets base
  [ "$status" -eq 0 ]
  grep -q -- '--from-file=github-app-key=' "$CALLS"
}

@test "refuses a foreign context before any secret is written" {
  make_stub "$STUBS" kubectl 'echo dv-cd-lc-prd-us-east-1'
  run run_secrets base
  [ "$status" -eq 3 ]
}

@test "late secrets are stubs in slice 1" {
  run run_secrets late
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped: holmes"* ]]
}
