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
repo**, mode 0600, for example `~/.config/<project>/agent.pem`. `*.pem` is gitignored and the
pre-commit hook refuses it, but the safest place is somewhere that is not inside a checkout.

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
  `dismiss_stale_reviews_on_push: true`, `require_last_push_approval: true`,
  `required_review_thread_resolution: false`, and `require_code_owner_review` set to `false`
  with `apply --minimal` (CODEOWNERS does not exist yet) and `true` with a plain `apply`.
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

`require_last_push_approval` means a commit pushed after an approval doesn't keep the approval.
It must not block an act-level PR that touches no code-owned file; the merge-mechanics spike on
a scratch branch is how to confirm that (section 4).

### `argoconna26-promote`: only the operator creates promotion branches

- **Target:** `refs/heads/promote/*`
- **Rules:** `creation` and `update`
- **Bypass actors:** the same single Admin repository role.

Why: promoting the agent to a higher autonomy level is a pull request from a `promote/*` branch.
If the App could create or push to such a branch it could open its own promotion, or alter one
after a human approved it. Only an admin can.

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
| Secret scanning push protection | enabled | Blocks the push itself when it contains a recognised token. Belt and braces with the local pre-commit hook and `gitleaks`. |

Secret scanning is free on public repositories. On a private fork you need GitHub Advanced
Security for these two.

## 4. What later slices add

These are not applied yet; the script's full mode and the preflight grow as the demo does.

- **Code-owner review** (`apply` without `--minimal`): `require_code_owner_review: true` on
  `argoconna26-tracked`, with a `CODEOWNERS` file that makes the promotion team the owner of the
  autonomy file (`aiops/autonomy.yaml`) and of the files that grant the agent more power. Raising
  the agent's level then always needs a human from that team. You create the team (visible,
  Write permission on the repo) in the organization first.
- **The required `policy-check` status:** a `required_status_checks` rule on the tracked
  branches naming the context `policy-check` from GitHub Actions (`integration_id: 15368`).
  The workflow that produces it lives on the tracked branch.
- **Merge-mechanics spike** (`apply --spike rehearse/<name>` and `apply --spike-remove`): a
  temporary fourth ruleset, `argoconna26-spike`, with those full rules on one scratch
  `rehearse/*` branch only, to test the App's auto-merge before the real branches carry them.
  The script refuses a branch that is in `RULESET_BRANCHES` or doesn't start with `rehearse/`.

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

`verify-integrity` lists a throwaway `rehearse/integrity-<timestamp>` branch in the rulesets,
pushes it, tries `git push --force` of its parent over it and expects GitHub to refuse
(`GH013: Repository rule violations found`). It then unlists the branch, re-applies the rulesets
and deletes the branch, even if the check failed.

The proof that the App itself is boxed in, run with the App credentials from `.env`:

```bash
cd bridge
uv run python -m bridge.cli try-direct-push --repo <owner>/<repo> \
  --branches build/demo,main --operator-ref promote/op-test-<timestamp>
```

For each listed branch it makes a commit whose parent is the branch head (unreachable, so
harmless), tries to move the branch to it, then tries to delete the branch. It tries to create
`promote/app-test-<timestamp>`, and tries to move `--operator-ref`, a promotion branch the
operator pushed beforehand (delete it afterwards). Every attempt must be refused. If one ever
succeeds, the check undoes it and fails.

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
| Script | `scripts/github-ruleset.sh apply [--minimal \| --spike BRANCH \| --spike-remove]`, `show`, `verify-integrity` |
| Admin role id used as the only bypass | `5` (repository role "Admin") |
| Names the scripts read | `demo.env`: `REPO_SLUG`, `BOT_LOGIN`, `PROMOTION_TEAM`, `RULESET_BRANCHES`, `RULESET_INTEGRITY`, `RULESET_TRACKED`, `RULESET_PROMOTE`, `POLICY_CHECK_CONTEXT`, `POLICY_CHECK_INTEGRATION_ID` |
| Secrets the bridge needs | `.env`: `GITHUB_APP_ID`, `GITHUB_INSTALLATION_ID`, `GITHUB_APP_KEY_PATH` (key file outside the repo) |
| `gh` scopes for the operator | `repo`, `read:org`, `workflow` |
| Bridge write switch | `DRY_FORGE=1` in the bridge Deployment turns every GitHub write into a `▸ dry: would ...` log line (reads still use the App). The committed Deployment has it unset, so the bridge posts for real; `GET /status` reports `dry_forge` |
| Where the agent's comments land (suggest level) | On the cause commit, or on its PR when it has one. Refusals land on the cause only once it is verified, otherwise on the synced revision |
