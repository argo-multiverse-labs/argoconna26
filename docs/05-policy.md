# 05. Policy

## Overview

Two policies, both written in Rego and run with conftest, both in `policy/`:

| Policy | Package | Applies to | Purpose |
|--------|---------|------------|---------|
| Golden path | `goldenpath` | Every app's rendered manifests | Every Deployment and Rollout carries the owner, tier and SLO labels, on the workload and on its pod template |
| Auto-fix | `autofix` | Pull requests opened by the agent | Decides whether the agent's fix PR is safe enough to merge without a human |

The second is what makes the `act` level possible. It does not judge the model or the cluster. It
judges a set of Git facts about the PR.

> **Status.** The policies, the facts extractor, the `policy-check` workflow and the laptop
> runner are on `build/demo`, and `policy-check` is a required status on the tracked branch
> (code-owner review is not on yet). Rung 3 has run end to end against the required check
> (`tests/e2e/rung3.sh`, verified after the fact by `tests/e2e/overnight-verify.sh`), and
> `tests/e2e/policy-negative.sh` shows the check failing on App-authored PRs that break a rule.
> Those PRs are labelled `policy-negative-test` and are not counted as fix-PR outcomes.

## Golden-path labels

`policy/golden_path.rego` denies a Deployment or Rollout that lacks any of
`example.dev/owner`, `example.dev/tier` or `slo.example.dev/success-rate`, either on the workload
or on `spec.template.metadata.labels`. The label keys and values are in `demo.env`. The checkout
Rollout reads the SLO target from its own pod label (`SLO_TARGET`), so the label is not only
metadata: it is the number the canary gate and the dashboard compare against.

Fixtures are in `policy/fixtures/golden_path/` (a good manifest, one missing the owner, one
missing the SLO label), and `policy/golden_path_test.rego` runs them.

## Git facts

`policy/facts/facts.py` (standard library plus PyYAML) turns a PR into JSON:

```
python3 policy/facts/facts.py --repo . --base <sha> --head <sha> --body-file <file> \
    --author-login <login> --author-type <type> --tracked-ref <ref>
```

The diff is taken from the merge base to the head, the same set GitHub shows. History questions
are asked of `--tracked-ref` only, so commits that exist only on the PR branch never count. If
the script cannot read or parse something, it exits 2 with nothing on stdout, and the check fails
instead of judging partial facts.

| Fact | Meaning |
|------|---------|
| `changed_files` | Every path in the PR |
| `config_changes` | Each changed key in a ConfigMap under `apps/<app>/config/` (file, key, from, to) |
| `rollout_changes` | Config-version annotation change on a workload (from, to) and whether anything else in it changed |
| `forbidden_changes` | Whether the PR touches an image, RBAC kinds, CRDs, or Applications (anything under `gitops/` or of kind Application, ApplicationSet, AppProject) |
| `to_value_seen_before` | Whether the new value already existed for that key at an earlier commit on the tracked branch |
| `cited_sha`, `cited_sha_on_branch`, `cited_sha_changed_key` | The `Cause:` line in the PR body, whether that commit is on the tracked branch, and whether it changed this key |
| `author` | The PR author's login and type |

## Auto-fix rules

`policy/autofix.rego` allows auto-merge only when `deny` is empty. Every rule is "deny unless
proven OK": a missing or mistyped fact denies, it never passes.

| Rule | Requires |
|------|----------|
| 1 | Exactly two files changed: one key in a file under `apps/<app>/config/`, and that app's workload file (the config-version annotation) |
| 2 | The config-version goes up by exactly one |
| 3 | The new value was already used for that key at an earlier commit on the tracked branch. A fix can only restore a past value, never invent one |
| 4 | No image, RBAC, CRD or Application change, and nothing in the Rollout except the annotation |
| 5 | The PR body cites a cause commit (`Cause: <40 hex>`), that commit is on the tracked branch, and it changed the same key |
| 6 | The author is the agent's GitHub App (`policy/data/agent.yaml`, which holds `BOT_LOGIN`) and its type is `Bot` |

`policy/autofix_test.rego` carries the unit tests, and `bridge/tests/` has a test that the
bridge's fix builder and PR template satisfy rules 1, 2, 4 and 5.

## The `policy-check` workflow

`.github/workflows/policy.yml` produces the status check `policy-check` (GitHub Actions,
`integration_id` 15368). On every pull request it:

1. Checks out the PR into `pr/`, and separately checks out the **base branch's** `policy/` into
   `base/`. Every later step runs from `$RUNNER_TEMP` with explicit paths, and Python runs with
   `-P`, so a `conftest.toml` or a `yaml.py` the PR adds is only a file in `pr/`: it can neither
   configure conftest nor shadow PyYAML.
2. Installs conftest at the pinned version, verifying its SHA-256.
3. Runs the Rego unit tests from the base copy.
4. Runs the golden-path rule on `kubectl kustomize` of every app, with the base copy.
5. If, and only if, the PR author is the agent's login (read from the base copy of
   `agent.yaml`), runs the facts extractor and the auto-fix rules, with the base copy. Human PRs
   skip the auto-fix rules.

It uses no secrets and a read-only token.

The same checks run on a laptop, with no cluster:

```bash
make policy-check                              # golden-path labels on every app
make policy-check BASE=<sha> HEAD=<sha>        # plus the auto-fix rules
make policy-verify                             # the Rego unit tests
```

(`scripts/policy-check.sh` takes more options: `--body-file`, `--author-login`, `--tracked-ref`,
`--policy-dir`.)

### Trust boundary

The check is only worth something if the agent cannot change how it runs.

- **The policy is the base branch's.** A PR cannot loosen the rules it is judged by, because
  they are read from the base ref, never from the PR's head.
- **The workflow file is not.** The workflow runs from the PR's merge ref (`pull_request`, not
  `pull_request_target`), so a PR that edited `policy.yml` could change how the check runs.
  What stops an agent PR doing that:
  - the GitHub App has no `workflows` permission, so GitHub refuses its commits under
    `.github/workflows/`;
  - for the agent's own PRs, auto-fix rule 1 denies any change outside the two fix files, so a
    PR that touches `.github/`, `policy/` or `aiops/autonomy.yaml` fails the required check;
  - `.github/` is code-owned by the promotion team, so a change there needs one of its members
    to review once `require_code_owner_review` is on in the tracked ruleset
    (`apply --with-policy-check`; the `--minimal` modes leave it off). It is off today.
- **The PR's tree configures nothing.** The tools run outside the PR's checkout (see the steps
  above). `policy-negative.sh` has two cases for this: `tamper-config` (a root `conftest.toml`
  with `no-fail = true` and a `yaml.py`) and `shadow-yaml` (a fix-shaped PR plus a `yaml.py`).
- **The policy directory is code-owned too** (`/policy/`), and so is `aiops/autonomy.yaml`.

The check is a *required* status on the tracked branch only in the `--with-policy-check` mode of
`scripts/github-ruleset.sh apply`, and the workflow must exist on that branch before you apply it,
or every PR waits for a check that never runs. [github-setup.md](./github-setup.md) has the details, including the `integration_id` that ties the
required check to GitHub Actions.

## What the policy does not see

It sees Git facts only: the diff, the history of the tracked branch, the PR author and body. It
does not see the cluster, the metrics, the model's reasoning or whether the fix will work. That
is deliberate. The policy can run on a hosted runner, outside the agent, and its verdict does not
depend on anything the agent could have influenced other than the PR itself.
