#!/usr/bin/env bats
# scripts/policy-check.sh: the local twin of the policy-check Action (no cluster)

load helpers

@test "golden path alone passes on the real apps" {
  run "$REPO_ROOT/scripts/policy-check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"apps/checkout/"* ]]
}

@test "--base without --head is a usage error" {
  run "$REPO_ROOT/scripts/policy-check.sh" --base abc
  [ "$status" -eq 2 ]
}

@test "a human author skips the auto-fix rules" {
  head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  run "$REPO_ROOT/scripts/policy-check.sh" --base "$head" --head "$head" --author-login someone
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-fix rules skipped"* ]]
}

@test "a bot PR with no diff fails closed" {
  head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  run "$REPO_ROOT/scripts/policy-check.sh" --base "$head" --head "$head" --body-file /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"rule 1:"* ]]
}

# ---------------------------------------------------------------- the Action's own step scripts
# Runs the workflow's run: blocks (read with yq) against a PR tree that carries a conftest.toml
# with no-fail and a yaml.py that shadows PyYAML (review 11-02): the check must still fail.
WF="$REPO_ROOT/.github/workflows/policy.yml"

setup_file() {
  export PYVENV="$BATS_FILE_TMPDIR/venv"
  uv venv --quiet "$PYVENV" && uv pip install --quiet --python "$PYVENV/bin/python" pyyaml==6.0.2
}

step_script() { yq -r ".jobs.\"policy-check\".steps[] | select(.name == \"$1\") | .run" "$WF"; }

action_setup() {
  WS="$BATS_TEST_TMPDIR/ws"
  export GITHUB_WORKSPACE="$WS" RUNNER_TEMP="$BATS_TEST_TMPDIR/rt"
  mkdir -p "$WS/base" "$RUNNER_TEMP"
  BASE_REF="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
  git clone -q "$REPO_ROOT" "$WS/pr"
  git -C "$WS/pr" checkout -q "$BASE_REF"
  git -C "$WS/pr" -c user.email=t@example.invalid -c user.name=t config commit.gpgsign false
  cp -r "$REPO_ROOT/policy" "$WS/base/policy"
  BASE_SHA="$(git -C "$WS/pr" rev-parse HEAD)"
  # PyYAML without touching the user's site-packages: a throwaway venv (a real interpreter; never
  # a python3 wrapper script, which uv's interpreter probe would call recursively).
  export PATH="$PYVENV/bin:$PATH"
}

tamper_files() { # DIR : the two files that used to turn the check green from the PR's tree
  printf 'no-fail = true\n' >"$1/conftest.toml"
  printf 'def safe_load(f):\n    return {"agent_login": "nobody"}\n' >"$1/yaml.py"
}

commit_pr() { git -C "$WS/pr" add -A && git -C "$WS/pr" -c user.email=t@example.invalid -c user.name=t commit -q -m "$1"; }

@test "the Action's tools run outside the PR checkout, Python with -P" {
  [ "$(yq -r '.jobs."policy-check".steps[0].with.path' "$WF")" = pr ]
  [ "$(yq -r '.jobs."policy-check".steps[1].with.path' "$WF")" = base ]
  while IFS= read -r name; do
    script="$(step_script "$name")"
    [[ "$(grep -v '^set ' <<<"$script" | grep -m1 .)" == 'cd "$RUNNER_TEMP"' ]] || { echo "step '$name' does not start in RUNNER_TEMP"; false; }
  done < <(yq -r '.jobs."policy-check".steps[] | select(.run) | .name' "$WF")
  ! grep -nE 'python3 +(-c|[^-P ])' "$WF"
  ! grep -n 'base-policy' "$WF"
}

@test "tamper-config: conftest.toml and yaml.py in the PR's tree do not skip or pass the auto-fix rules" {
  action_setup
  tamper_files "$WS/pr"
  sed -i -E 's/^( *newTag: *v[0-9]+\.[0-9]+\.)([0-9]+)/\1999/' "$WS/pr/apps/checkout/kustomization.yaml"
  commit_pr "image change plus tamper files"
  agent="$(yq -r .agent_login "$WS/base/policy/data/agent.yaml")"
  run env PR_AUTHOR_LOGIN="$agent" PR_AUTHOR_TYPE=Bot PR_BODY="" BASE_SHA="$BASE_SHA" \
    HEAD_SHA="$(git -C "$WS/pr" rev-parse HEAD)" BASE_REF="$BASE_REF" bash -c "$(step_script "Auto-fix rules (only for the agent's PRs)")"
  [ "$status" -ne 0 ]
  [[ "$output" != *"auto-fix rules skipped"* ]]
  [[ "$output" == *"rule 4:"* ]]
}

@test "tamper-config: conftest.toml in the PR's tree does not pass the golden-path rule" {
  action_setup
  tamper_files "$WS/pr"
  sed -i '0,/example\.dev\/owner:/{/example\.dev\/owner:/d}' "$WS/pr/apps/pricing/deploy/deployment.yaml"
  commit_pr "label removed plus tamper files"
  run bash -c "$(step_script "Golden-path labels on every app")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required label"* ]]
}

@test "tamper-config: the Rego unit tests run from base/ with no PR config" {
  action_setup
  tamper_files "$WS"   # even at the workspace root
  run bash -c "$(step_script "Policy unit tests (base-branch policy)")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
}
