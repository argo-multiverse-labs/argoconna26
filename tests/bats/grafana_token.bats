#!/usr/bin/env bats
# Tests for scripts/grafana-token.sh (curl and kubectl are stubs; nothing leaves the machine)

load helpers

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$FIXTURE"
  mkdir -p "$FIXTURE/.kube"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  STATE="$BATS_TEST_TMPDIR/state"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$STATE"
  : > "$CALLS"
  # curl: a tiny Grafana. Records argv only; credentials arrive through -K files.
  make_stub "$STUBS" curl 'echo "CURL: $*" >> "'"$CALLS"'"
    method=GET; cfg=""; url=""
    while [ $# -gt 0 ]; do
      case "$1" in -X) method="$2"; shift 2 ;; -K) cfg="$2"; shift 2 ;; -d|-H|--max-time|-o) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
    done
    path="${url#*://*/}"; path="/${path#/}"
    [ -z "$cfg" ] || cp "$cfg" "'"$STATE"'/last-cfg" 2>/dev/null || true
    case "$method $path" in
      "GET /api/health") echo "{}" ;;
      "GET /api/org")
        tok="$(sed -n "s/^header = \"Authorization: Bearer \(.*\)\"$/\1/p" "'"$STATE"'/last-cfg")"
        [ -f "'"$STATE"'/valid" ] && [ "$tok" = "$(cat "'"$STATE"'/valid")" ] && echo "{}" || exit 22 ;;
      "GET /api/serviceaccounts/search"*)
        if [ -f "'"$STATE"'/sa" ]; then echo "{\"serviceAccounts\":[{\"id\":5,\"name\":\"cdevents-sim\"}]}"; else echo "{\"serviceAccounts\":[]}"; fi ;;
      "POST /api/serviceaccounts") touch "'"$STATE"'/sa"; echo "{\"id\":5}" ;;
      "GET /api/serviceaccounts/5/tokens")
        if [ -f "'"$STATE"'/valid" ]; then echo "[{\"id\":9,\"name\":\"cdevents-sim\"}]"; else echo "[]"; fi ;;
      "DELETE /api/serviceaccounts/5/tokens/9") rm -f "'"$STATE"'/valid"; echo "{}" ;;
      "POST /api/serviceaccounts/5/tokens") n=$(( $(cat "'"$STATE"'/n" 2>/dev/null || echo 0) + 1 )); echo $n > "'"$STATE"'/n"
        echo "glsa-token-$n" > "'"$STATE"'/valid"; echo "{\"key\":\"glsa-token-$n\"}" ;;
      *) echo "unexpected: $method $path" >&2; exit 22 ;;
    esac'
  make_stub "$STUBS" kubectl 'echo "ARGS: $*" >> "'"$CALLS"'"
    case "$*" in
      "config current-context") echo kind-argoconna26 ;;
      *"get namespace"*) ;;
      *"get secret cdevents-grafana"*"jsonpath"*) [ -f "'"$STATE"'/secret" ] && base64 -w0 < "'"$STATE"'/secret" || true ;;
      *"get secret"*) echo "{\"metadata\":{}}" ;;
      *"create secret generic"*)
        d="$(grep -o -- "--from-file=/[^ ]*" <<<"$*" | cut -d= -f2-)"
        printf %s "$(cat "$d/token")" > "'"$STATE"'/secret.next"
        echo "apiVersion: v1"; echo "kind: Secret" ;;
      *"apply"*"-f -"*) cat > /dev/null; mv "'"$STATE"'/secret.next" "'"$STATE"'/secret"; echo applied ;;
    esac'
  export PATH="$STUBS:$PATH" TOOLS_BIN="$STUBS"
  pw=admin-s3cret-pw
  printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$pw" > "$FIXTURE/.env"
  chmod 600 "$FIXTURE/.env"
}

run_token() { ( cd "$FIXTURE" && "$REPO_ROOT/scripts/grafana-token.sh" ); }

@test "first run creates the service account and stores the token" {
  run run_token
  [ "$status" -eq 0 ]
  grep -q -- '-X POST .*/api/serviceaccounts$' "$CALLS"
  [ "$(cat "$STATE/secret")" = "glsa-token-1" ]
  grep -q 'ARGS: .*apply --server-side' "$CALLS"
}

@test "neither the admin password nor the token appears in any argument or output" {
  run run_token
  [ "$status" -eq 0 ]
  ! grep -q 'admin-s3cret-pw' "$CALLS"
  ! grep -q 'glsa-token' "$CALLS"
  [[ "$output" != *admin-s3cret-pw* ]]
  [[ "$output" != *glsa-token* ]]
}

@test "second run with a working token changes nothing" {
  run run_token
  [ "$status" -eq 0 ]
  : > "$CALLS"
  run run_token
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip:"* ]]
  [ "$(cat "$STATE/secret")" = "glsa-token-1" ]
  ! grep -q -- '-X POST' "$CALLS"
}

@test "a rejected token is replaced and the service account is reused" {
  run run_token
  [ "$status" -eq 0 ]
  echo revoked-elsewhere > "$STATE/valid"        # Grafana no longer accepts the stored token
  : > "$CALLS"
  run run_token
  [ "$status" -eq 0 ]
  [[ "$output" == *"reusing service account"* ]]
  [ "$(cat "$STATE/secret")" = "glsa-token-2" ]
  ! grep -q -- '-X POST .*/api/serviceaccounts$' "$CALLS"
}

@test "refuses a foreign context" {
  make_stub "$STUBS" kubectl 'echo dv-cd-lc-prd-us-east-1'
  run run_token
  [ "$status" -eq 3 ]
  [ ! -f "$STATE/secret" ]
}

@test "dies when the admin password is missing" {
  : > "$FIXTURE/.env"
  run run_token
  [ "$status" -ne 0 ]
  [[ "$output" == *"GRAFANA_ADMIN_PASSWORD"* ]]
}
