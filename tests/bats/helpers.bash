# Shared bats helpers.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
export REPO_ROOT

# make_fixture_repo DIR : a throwaway git repo with one commit on branch "main".
make_fixture_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "test@example.invalid"
  git -C "$dir" config user.name "test"
  git -C "$dir" config commit.gpgsign false
  echo seed > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -q -m seed
}

# make_stub BINDIR NAME 'script body' : an executable stub on a private bin dir.
make_stub() {
  local bindir="$1" name="$2" body="$3"
  mkdir -p "$bindir"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$bindir/$name"
  chmod +x "$bindir/$name"
}

# Run a snippet in a fresh bash with common.sh sourced, cwd = $FIXTURE.
# Usage: run in_fixture 'require_context'
in_fixture() {
  ( cd "$FIXTURE" && bash -c ". '$REPO_ROOT/scripts/common.sh'; $1" )
}

# Wait (bounded) until a file exists.
wait_file() {
  local f="$1" i
  for i in $(seq 1 100); do [[ -e "$f" ]] && return 0; sleep 0.1; done
  return 1
}
