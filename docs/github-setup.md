# GitHub setup

Everything this demo needs on the GitHub side, so you can reproduce it on your own fork.
Nothing here is secret: owners, logins and IDs are placeholders. The repo `demo.env` holds the
names the scripts use (`REPO_SLUG`, `BOT_LOGIN`, `PROMOTION_TEAM`, `RULESET_BRANCHES`,
`RULESET_INTEGRITY`, `RULESET_TRACKED`, `RULESET_PROMOTE`); change them there for a fork.

The idea in one paragraph: an agent (the bridge) may write to Git only through a GitHub App
whose permissions are small, and the repository rulesets make sure that even a mistake in the
bridge cannot rewrite history, push to the branch Argo CD tracks, or touch a promotion branch.
The operator (you, with an admin `gh` login) is the only party that can bypass the pull request
rules, and nobody at all can delete or force-push a protected branch.

## 1. The GitHub App

**Name:** `<app-name>`, for example `argoconna26-agent`. GitHub shows its bot as
`<app-name>[bot]`; that string is `BOT_LOGIN` in `demo.env`. Create it under the owning
organization (Settings, Developer settings, GitHub Apps, New GitHub App).

**Webhook:** inactive. The bridge is called by Argo CD Notifications; it never
receives GitHub events, so there is no URL to expose and no webhook secret to manage.
**Subscribe to events:** none.

**Repository permissions** (everything else stays "No access"):

| Permission | Level | Why |
|---|---|---|
| Contents | Read and write | The bridge reads files at a ref and, at the propose and act levels, creates branches and commits for a fix. Commit comments (the suggest level) also need it. |
| Pull requests | Read and write | Open the fix PR, comment on a PR, enable auto-merge on an act-level PR. |
| Checks | Read | See whether the required `policy-check` has passed before the bridge relies on a merge. |
| Commit statuses | Read | Optional. Lets the bridge see status-style checks too. |
| Metadata | Read | Mandatory for every App; GitHub adds it for you. |

**Deliberately not granted:**

- **Workflows.** Without it the App cannot create or edit anything under `.github/workflows/`,
  so it cannot rewrite the policy check that gates its own merges.
- **Administration.** Without it the App cannot read or change rulesets, branch protection or
  repo settings. The rulesets in section 2 can only be changed by a human admin.
- **Actions.** No re-running or cancelling workflows, no reading secrets.

The bridge also requests only `contents: write`, `pull_requests: write` and `checks: read` when it
mints each installation token (see `bridge/src/bridge/github_auth.py`), so a token never carries
more than that, whatever the installation allows.

**Where can it be installed:** "Only on this account", then install it on **one repository**
(your fork of this repo), not "All repositories".

**Private key:** on the App's page, "Generate a private key". Save the `.pem` **outside the
repo**, mode 0600, for example `~/.config/<project>/agent.pem`. `*.pem` is gitignored, but the
safest place is somewhere that is not inside a checkout. This repo ships no Git hook (hooks live
in `.git/hooks/`, which a clone doesn't copy), so we recommend adding a local `gitleaks`
pre-commit hook yourself (section 3).

**IDs and where they go.** Copy these into `.env` (mode 0600, gitignored; `.env.example` has the
blank keys):

| `.env` key | Where to find the value |
|---|---|
| `GITHUB_APP_ID` | The App's settings page, "App ID" |
| `GITHUB_INSTALLATION_ID` | The number at the end of the URL of the installation's settings page (`/settings/installations/<id>`) |
| `GITHUB_APP_KEY_PATH` | The path of the `.pem` you saved |

`make secrets-base` loads the key and IDs into the `bridge-secrets` Secret in the cluster.
No token or key is ever written to a committed file.

**Check it:** `scripts/github-ruleset.sh` does not touch the App. The proof that the App is
boxed in is `python -m bridge.cli try-direct-push` (section 5).

## 2. The rulesets

Three standing rulesets, created and updated by `scripts/github-ruleset.sh apply`. They use
GitHub's repository rulesets (Settings, Rules), not classic branch protection, because rulesets
let the integrity rule have an empty bypass list.

`RULESET_BRANCHES` in `demo.env` lists the branches Argo CD tracks: `build/demo` while you
build, `main` after the freeze. The first two rulesets cover every listed branch.

### `argoconna26-integrity`: nobody rewrites history

- **Target:** `refs/heads/<each branch in RULESET_BRANCHES>`
- **Rules:** `deletion` and `non_fast_forward` (no branch delete, no force-push)
- **Bypass actors:** none. Not the App, not a team, **not even a repository admin**.

Why: the tracked branch is the demo's source of truth, and an agent loop is the thing most
likely to do something clever with `git push --force`. With an empty bypass list no credential
can do it, including yours. The price is that to delete a scratch branch you first remove it
from `RULESET_BRANCHES` and re-apply; the script does that for you in `verify-integrity`.

### `argoconna26-tracked`: changes arrive by pull request

- **Target:** the same branches.
- **Rules:** `pull_request` with `required_approving_review_count: 0`,
  `dismiss_stale_reviews_on_push: true`, `require_last_push_approval: false`,
  `required_review_thread_resolution: false`, and `require_code_owner_review` set to `false`
  with `apply --minimal` (for a repository that has no CODEOWNERS yet; this one does) and `true`
  with a plain `apply`.
  `apply --with-policy-check` also adds the required `policy-check` status (section 4);
  `apply --minimal --with-policy-check` adds it while code-owner review stays off.
- **Bypass actors:** exactly one: the built-in **Repository role "Admin"** (`actor_type:
  RepositoryRole`, `actor_id: 5`, `bypass_mode: always`).

Why: the operator scripts that stage the demo (push a bad config, revert it) push straight to the
tracked branch, which only an admin can do. The App and the promotion team are never bypass
actors, so everything the agent writes must be a pull request. Zero required approvals is
deliberate: at the act level the bridge turns on auto-merge for a small, policy-checked change,
and it must be able to merge without a human review. "A human merges at the propose level" is
therefore enforced by the bridge (it never calls merge or auto-merge on that path, and a unit
test says so), not by GitHub. Be honest about that if you present the demo.

What an admin push looks like once the ruleset is on: the push succeeds, and GitHub prints
`remote: Bypassed rule violations for refs/heads/<branch>: Changes must be made through a pull
request.` That line is expected for the operator scripts and for build-side pushes made with an
admin login; it is GitHub recording the bypass, not an error. An App push to the same branch
gets a 422 with "Repository rule violations found" instead.

#### Why `require_last_push_approval` is off

`require_last_push_approval: true` means the most recent push to a PR must be approved by
someone other than the person (or App) who pushed it. We started with it on, then tested it in
the merge-mechanics spike (section 4) on a scratch branch with the full rule set: an
App-authored PR with a green `policy-check` and **zero** required approvals stayed `BLOCKED`,
because the App is both the author and the last pusher, so nobody had approved its last push.
With only that one setting turned off, the same kind of PR went `CLEAN` and auto-merged in 20 s.
With it on, the act level could never auto-merge anything, so the script now writes `false`.

We originally wanted it so that a commit pushed to an approved `promote/*` branch would not keep
the approval. Two other rules cover that case: `dismiss_stale_reviews_on_push: true` drops an
approval when a new commit lands, and the `argoconna26-promote` ruleset stops anyone but the
admin role from pushing to a promotion branch at all.

`RULESET_LAST_PUSH_APPROVAL=true scripts/github-ruleset.sh apply ...` turns it back on, for
example to repeat the test on your fork. The default is `false`.

#### What GitHub enforces, and what the bridge enforces

With these settings GitHub does **not** require a human approval on an ordinary PR to the
tracked branch. What stops the agent at each level:

| Level | What the agent may do | Enforced by |
|---|---|---|
| suggest | Comment only | The bridge (it opens no PR at this level) |
| propose | Open a PR; a human merges it | The bridge never calls merge or auto-merge on this path (unit-tested). GitHub only requires that the change arrives by PR. |
| act | Open a PR and turn on auto-merge | GitHub merges only when `policy-check` passes (`required_status_checks`, slice 5) |
| any | Raise its own level | GitHub: `aiops/autonomy.yaml` is code-owned by the promotion team, and `require_code_owner_review` (plain `apply`) blocks the merge until a team member approves. The second spike test (section 4) checks this on a scratch branch. |
| any | Push to, rewrite or delete the tracked branch, or touch `promote/*` | GitHub: the three rulesets (the App is never a bypass actor) |

#### Parameters GitHub adds on its own

`show` prints a few `pull_request` parameters the script never sends. They are server defaults:
`require_extra_approval_for_unattributed_changes: true`, `required_reviewers: []`,
`dismissal_restriction: {enabled: false}` and `allowed_merge_methods: [merge, squash, rebase]`.
In the spike, an App-authored PR auto-merged with them in place, so they don't block the act
level. You can ignore them when you compare `show` with this page.

#### The script is the only source of these rules

`apply` replaces each ruleset in full (`PUT` by id). Anything you change by hand in the GitHub
UI is lost on the next `apply` or `verify-integrity`. Change the script (or the environment
knobs above) instead. `verify-integrity` reads the tracked ruleset's current mode (minimal, full,
or with the policy check) and restores that same mode when it cleans up.

### `argoconna26-promote`: only the operator creates, moves or deletes promotion branches

- **Target:** `refs/heads/promote/*`
- **Rules:** `creation`, `update` and `deletion`
- **Bypass actors:** the same single Admin repository role.

Why: promoting the agent to a higher autonomy level is a pull request from a `promote/*` branch.
If the App could create or push to such a branch it could open its own promotion, or alter one
after a human approved it. If it could delete one, it could close a pending promotion PR (GitHub
closes a PR whose head branch is deleted). `update` does not cover deletion in GitHub rulesets,
so `deletion` is listed on its own. Only an admin can do any of the three.

### Labels

`apply` also creates two labels with `gh label create --force`, because `gh pr edit --add-label`
fails on a label that doesn't exist: `demo-reset` and `policy-negative-test`.

## 3. Repository settings

Set with the GitHub API (admin login), and checked again by the preflight:

```bash
gh api -X PATCH repos/<owner>/<repo> \
  -F allow_auto_merge=true \
  -f 'security_and_analysis[secret_scanning][status]=enabled' \
  -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'

gh api repos/<owner>/<repo> --jq '{allow_auto_merge, security_and_analysis}'
```

| Setting | Value | Why |
|---|---|---|
| `allow_auto_merge` | `true` | The act level asks GitHub to merge a PR when its required checks pass (`enablePullRequestAutoMerge`). Without it the call fails. |
| Secret scanning | enabled | The repo is public; this alerts on a committed credential. |
| Secret scanning push protection | enabled | Blocks the push itself when it contains a recognised token format. It does not catch a private key file or an unrecognised token, so also run `gitleaks` locally (below). |

Secret scanning is free on public repositories. On a private fork you need GitHub Advanced
Security for these two.

**Recommended: a local `gitleaks` pre-commit hook.** The repo does not ship one, and a clone
does not copy `.git/hooks/`, so add it yourself in your clone:

```bash
printf '#!/bin/sh\nexec gitleaks git --pre-commit --staged --redact\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

## 4. Optional modes

These are modes and options of the script. `scripts/github-ruleset.sh show` tells you which one is
live on your repository.

- **Code-owner review** (`apply` without `--minimal`): `require_code_owner_review: true` on
  `argoconna26-tracked`, with a `CODEOWNERS` file that makes the promotion team the owner of the
  autonomy file (`aiops/autonomy.yaml`) and of the files that grant the agent more power. Raising
  the agent's level then always needs a human from that team. You create the team (visible,
  Write permission on the repo) in the organization first.
- **The required `policy-check` status** (`apply --with-policy-check`): a
  `required_status_checks` rule on the tracked branches naming the context `policy-check` from
  GitHub Actions (`integration_id: 15368`). The workflow that produces it is
  `.github/workflows/policy.yml`, and it lives on the tracked branch. Don't apply it before that
  workflow exists there, or every PR waits for a check that never runs.
  `apply --minimal --with-policy-check` adds the check with code-owner review still off, for a
  fork (or this repo) that has the workflow but not yet the promotion-board team.
- **Merge-mechanics spike** (`apply --spike rehearse/<name>` and `apply --spike-remove`): a
  temporary fourth ruleset, `argoconna26-spike`, with those full rules on one scratch
  `rehearse/*` branch only, to test the App's auto-merge before the real branches carry them.
  The script refuses a branch that is in `RULESET_BRANCHES` or doesn't start with `rehearse/`.

  What the spike found (2026-11-01): GraphQL `enablePullRequestAutoMerge` works with the App's
  installation token; a `policy-check` from GitHub Actions (`integration_id: 15368`) satisfies
  the required-check rule on a bot PR; and `require_last_push_approval: true` blocks every
  App-authored PR (section 2), so it is off. Two practical notes: a rule change on a PR that is
  already waiting does not wake auto-merge up, so change rules before opening the PR; and a
  stub workflow with a bare `pull_request:` key under an `on:` mapping never started a job for
  us, while `on: [pull_request]` did.

  The second spike test opens an App PR that raises `aiops/autonomy.yaml`, and expects it to
  stay `REVIEW_REQUIRED` and `BLOCKED` with the check green. Before running it, check that the
  block can only come from code-owner review:
  `scripts/github-ruleset.sh show | jq '.[]|select(.name=="argoconna26-spike")|.rules[]|select(.type=="pull_request")|.parameters.require_last_push_approval'`
  must print `false`.

  `bridge.cli spike-pr` deletes its `agent/spike-*` head branch once the PR is merged or
  closed (the repo keeps head branches after a merge). When you finish the spike, also check
  that `git ls-remote origin 'refs/heads/agent/spike-*'` prints nothing.

## 5. Apply and verify

You need an admin login on the repo. The `gh` token needs the scopes **`repo`**, **`read:org`**
and **`workflow`** (`gh auth refresh -s repo,read:org,workflow`): `repo` for rulesets and
settings, `read:org` to look up team membership, and `workflow` to push workflow files from the
operator's clone.

```bash
scripts/github-ruleset.sh show                 # list the rulesets as normalized JSON
scripts/github-ruleset.sh apply --minimal      # create or update the three, plus the labels
scripts/github-ruleset.sh show                 # expect exactly three
scripts/github-ruleset.sh verify-integrity     # force-push to a listed scratch branch must be refused
```

`apply` is idempotent: it looks a ruleset up by name and updates it in place by id.

`verify-integrity` lists a throwaway `rehearse/integrity-<timestamp>` branch in the rulesets and
pushes it. As a control, it then pushes one more commit as a fast-forward, which must succeed
(the admin role bypasses `argoconna26-tracked`). Then it tries `git push --force` of the parent
over it. The check passes only when GitHub refuses with `GH013: Repository rule violations
found` **and** `Cannot force-push to this branch`: that rule is in `argoconna26-integrity` only,
and the control shows `argoconna26-tracked` isn't the one refusing. It then unlists the branch,
re-applies the rulesets in their current mode and deletes the branch, even if the check failed.

The proof that the App itself is boxed in. `bridge.cli` reads its settings from the environment
only, so load `demo.env` and `.env` first. As the operator, push a promotion branch for it to
attack, run the check, then delete that branch:

```bash
ts=$(date +%s)
git push origin "$(git rev-parse origin/build/demo):refs/heads/promote/op-test-${ts}"
bash -c '. scripts/common.sh; load_env; cd bridge; uv run python -m bridge.cli try-direct-push --operator-ref promote/op-test-'"${ts}"
git push origin --delete "promote/op-test-${ts}"
```

`--repo` and `--branches` default to `REPO_SLUG` and `RULESET_BRANCHES`. (In zsh, keep the braces
in `${ts}`: `$x:r` is a zsh modifier.)

For each listed branch it makes a commit whose parent is the branch head and whose tree is the
head's tree (so it changes no file), tries to move the branch to it, then tries to delete the
branch. It tries to create `promote/app-test-<timestamp>`, and tries to move and then delete
`--operator-ref`. Every attempt must be refused. The last line says who refused what, for
example `7/7 attempts refused: 6 by a ruleset, 1 by the default-branch guard`.

If an attempt ever succeeds, the check fails and undoes what it can: a deleted branch is
re-created at its old commit, and a stray `promote/*` branch is deleted. A successful *move* of
a branch under `argoconna26-integrity` cannot be undone by anyone, because moving it back is a
force-push and that ruleset has no bypass. The branch then carries one probe commit with the
same tree as its parent, so no file changed. To remove it, take the branch out of
`RULESET_BRANCHES`, `apply`, reset the branch, and put it back. The check prints this step.

Two refusals don't carry a ruleset message, and the check handles them explicitly:

- Deleting the **default branch** is refused by GitHub's own default-branch guard before the
  rulesets are consulted ("Cannot delete the default branch"). The check labels this as the
  guard, not a ruleset. (When `main` is also the tracked branch, the integrity ruleset blocks
  deletion as well.)
- Creating a ref under a name a ruleset forbids returns only "Reference update failed". The
  check then creates a ref under an unprotected name (`rehearse/control-<timestamp>`); if that
  works and is removed again, the `promote/*` refusal is the ruleset's doing.

## 6. Quick reference

| Thing | Value |
|---|---|
| Script | `scripts/github-ruleset.sh apply [--minimal [--with-policy-check] \| --with-policy-check \| --spike BRANCH \| --spike-remove]`, `show`, `verify-integrity` |
| Script knob | `RULESET_LAST_PUSH_APPROVAL` (environment, `true` or `false`, default `false`) |
| Admin role id used as the only bypass | `5` (repository role "Admin") |
| Names the scripts read | `demo.env`: `REPO_SLUG`, `BOT_LOGIN`, `PROMOTION_TEAM`, `RULESET_BRANCHES`, `RULESET_INTEGRITY`, `RULESET_TRACKED`, `RULESET_PROMOTE`, `POLICY_CHECK_CONTEXT`, `POLICY_CHECK_INTEGRATION_ID` |
| Secrets the bridge needs | `.env`: `GITHUB_APP_ID`, `GITHUB_INSTALLATION_ID`, `GITHUB_APP_KEY_PATH` (key file outside the repo) |
| `gh` scopes for the operator | `repo`, `read:org`, `workflow` |
| Bridge write switch | `DRY_FORGE=1` in the bridge Deployment turns every GitHub write into a `▸ dry: would ...` log line (reads still use the App). The committed Deployment has it unset, so the bridge posts for real; `GET /status` reports `dry_forge` |
| Where the agent's comments land (suggest level) | On the cause commit, or on its PR when it has one. Refusals land on the cause only once it is verified, otherwise on the synced revision |
