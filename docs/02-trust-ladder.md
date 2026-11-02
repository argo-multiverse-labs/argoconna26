# 02. The Trust Ladder

## Overview

The agent has one setting that matters: its autonomy level. It is a file in Git,
`aiops/autonomy.yaml`, so changing it is a commit, a diff and (for a raise) a reviewed pull
request. The bridge reads it again for every incident.

```yaml
apiVersion: aiops.example.dev/v1
kind: Autonomy
level: suggest
since: "2026-11-02"
promotion: null
touchpoints: {suggest: 4, propose: 1, act: 1}
```

| Field | Meaning |
|-------|---------|
| `level` | `suggest`, `propose` or `act` |
| `since` | The date the agent reached this level |
| `promotion` | The record of the last raise, or `null`: `from_level`, `dry_run_score`, `approver_required` (a team, never a person), `approved_by` (a role and a review link, or `admin-bypass`; never a login) and `pr` |
| `touchpoints` | Steps a human must take at each level. It feeds the dashboard's touchpoints panel. It is a defined count, not a measurement |

## The levels

| Level | The agent may | A human | Pipeline |
|-------|---------------|---------|----------|
| `suggest` | Comment its analysis on the cause commit, or on the PR that introduced it | Reads it and makes the fix | `_Run.suggest` in `bridge/src/bridge/pipeline.py` |
| `propose` | Open one fix PR | Reviews and merges it | `_Run.propose` |
| `act` | Open the fix PR and turn on auto-merge | Reviews it after the fact | `_Run.act` |

All three share the first steps: read the level, ask HolmesGPT, run the guardrails, render, scan
for personal data. Only the last step differs. See [04](./04-bridge-and-holmes.md).

**The fail-safe.** If `autonomy.yaml` is missing, cannot be read, is not valid YAML or fails
validation, the bridge uses `suggest` and logs the reason (`▸ autonomy: fail-safe suggest`).
Least autonomy is the default.

**At `act`.** The bridge opens the PR and asks GitHub to merge it when the required checks pass
(GraphQL `enablePullRequestAutoMerge`). If GitHub says the PR is already mergeable (no required
check holds it), the bridge does not merge blindly. It polls `policy-check` on the PR's head and
merges only on `success`, giving up after `ACT_CHECK_TIMEOUT_S` (600 s) and leaving the PR for a
human with a comment. If `policy-check` fails, the PR is left open and a single comment says so.

## Promoting

A promotion is a pull request that changes only `aiops/autonomy.yaml`.

```bash
make promotion-pr-ensure LEVEL=propose     # or LEVEL=act
```

`scripts/promotion-pr.sh ensure`:

1. Refuses unless the target is exactly one level above the current one.
2. Closes any open `promote/*` PR ("superseded by a fresh promotion PR").
3. Creates a branch `promote/<level>-<timestamp>-<random>` in the operator clone, sets the new
   `level`, `since` and a `promotion` record (with `approved_by: null`), commits, and pushes the
   branch.
4. Opens the PR as the operator's own `gh` login, with a body rendered from
   `scripts/templates/promotion-pr-body.md`. No text can be passed in. The body states the dry-run
   score against the bar (`PROMOTION_SCORE_BAR`), the time at the current level against the
   target weeks (`PROMOTION_WEEKS_*`), and who approves. The criteria are a first draft that the
   promotion board owns and can rewrite.

The operator authored the PR, so GitHub does not let them approve it. Another member of the
promotion team approves and merges. If you run the demo alone, an admin can merge:

```bash
scripts/promotion-pr.sh verify <number>          # head and diff are exactly what ensure pushed
scripts/promotion-pr.sh merge <number> --admin   # logged as admin-bypass
make promotion-record-approval PR=<number>       # after the merge
```

`verify` fails (exit 8) if the PR head moved or the diff is more than `autonomy.yaml`. Without
`--admin`, `merge` requires an approving review on the recorded head. `record-approval` then
writes `promotion.approved_by` as either `promotion-board member (review <url>)` or
`admin-bypass`, and `promotion.pr`, in a follow-up commit. The record never claims an approval
that did not happen and never names a person.

## Demoting

```bash
make demote
```

Lowers the level by one step as a forward commit pushed directly to the tracked branch. It also
sets `since` to today and clears the `promotion` record. Lowering
trust is the safe direction, so it needs no review. It is a normal commit, not a force-push, and
the next incident uses the lower level.

## What GitHub enforces, and what the bridge enforces

The tracked-branch ruleset requires pull requests but **zero** approvals. That is deliberate: at
`act` the bridge must be able to auto-merge without a human review. The consequence is that
"a human merges at `propose`" is held by the bridge, not by a GitHub approval rule.

| Constraint | Held by | How |
|------------|---------|-----|
| At `suggest` the agent opens no PR | The bridge | The `suggest` path only posts comments |
| At `propose` the agent never merges | The bridge | The path never calls merge or auto-merge; a unit test asserts it |
| At `act` a merge needs a passing `policy-check` | GitHub | `required_status_checks` in the tracked ruleset (the `--with-policy-check` mode of `scripts/github-ruleset.sh apply`), plus the bridge's own check in its fallback |
| The agent cannot raise its own level | GitHub | `aiops/autonomy.yaml` is code-owned by the promotion team; with `require_code_owner_review` on (`apply --with-policy-check`; `--minimal` leaves it off, and it is off until the promotion-board team exists) an App-authored PR that edits it stays `REVIEW_REQUIRED` and `BLOCKED`. Today the required `policy-check` is what fails such a PR (rule 1) |
| The agent cannot open or alter a promotion | GitHub | The `promote/*` ruleset allows only the admin role to create, update or delete those branches. The App is never a bypass actor |
| The agent cannot push to, rewrite or delete the tracked branch | GitHub | The integrity ruleset (`deletion`, `non_fast_forward`, no bypass actors) and the tracked ruleset (pull request required) |
| The agent cannot change the policy or the check that gates it | GitHub | The check runs the base branch's `policy/`, the App has no `workflows` permission, auto-fix rule 1 denies an agent PR that touches them, and the check's tools run outside the PR's checkout. `policy/` and `.github/` are also code-owned (binding once code-owner review is on) |
| The agent writes only PRs and comments | The bridge and the App's permissions | Contents, pull requests and checks only; no administration, no workflows |

CODEOWNERS (`.github/CODEOWNERS`) has no `*` line on purpose: ordinary changes need no
code-owner review. Only three paths do: `/aiops/autonomy.yaml`, `/policy/` and `/.github/`.

The operator's admin login can bypass the pull-request rule (the operator scripts push straight
to the tracked branch) but not the integrity ruleset: nobody can delete or force-push a listed
branch. `docs/github-setup.md` has the rulesets in full, and
`python -m bridge.cli try-direct-push` is the check that the App itself is boxed in.

Whether the rulesets on your repository are in this configuration is easy to check:
`scripts/github-ruleset.sh show` prints them as normalized JSON.

## Design choices

- **Why a file in Git.** The level is auditable, diffable, revertible and reviewable with the same
  tools as any other change. A runtime flag in a database would not have a reviewer.
- **Why the fail-safe is `suggest`.** A broken file should never produce more autonomy.
- **Why promotion needs a record.** The dry-run score, the time at the level and the approver are
  in the PR and in the file. Promotion criteria are proposals for the board, and the demo
  compresses time.
