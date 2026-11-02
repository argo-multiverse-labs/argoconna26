# 06. Operations

## Overview

Everything is driven from the `Makefile`. `make help` lists the targets with a one-line
description. Names live in `demo.env`, pins in `versions.env`, secrets in `.env`. No version or
name is hardcoded elsewhere, and `make consistency` checks that.

## Isolated kubeconfig and the cluster lock

- **Isolated kubeconfig.** The kind cluster is `argoconna26`, with context `kind-argoconna26` and
  its own kubeconfig at `.kube/argoconna26.yaml` in the main checkout (`KUBECONFIG_REL`). The
  Makefile exports `KUBECONFIG` and the Helm config, cache and data directories to that tree.
  Your default kubeconfig is never read or written. Every script that touches the cluster checks
  the context first and exits (code 3) on any other.
- **The main checkout, from worktrees.** `MAIN_ROOT` resolves to the main checkout even from a
  git worktree, so worktrees share one kubeconfig, one lock and one set of local state.
- **Cluster lock.** Targets that change the cluster take an exclusive `flock`
  (`.kube/cluster.lock`), re-entrant for the processes they start. A second run waits or exits
  with code 5 instead of interleaving two operations.
- **Pinned tools first.** `TOOLS_BIN` is put first on `PATH`, so the pinned versions win over
  whatever else is installed. Override it on the command line or in `.env`.

## Build and teardown

| Target | What it does |
|--------|--------------|
| `make vendor` | Checks that required tools exist and pinned ones are at the pinned version |
| `make build-all` | The whole stack; safe to run twice |
| `make rebuild` | `rm-kind` then `build-all` |
| `make rm-kind` | Deletes the cluster and its kubeconfig; first exports LiteLLM spend if the cluster is up |
| `make verify-idempotent` | `rm-kind`, `build-all`, snapshot, `build-all` again, compare object UIDs and restart counts, `preflight` |
| `make wait-platform` | Waits until every Application is Synced and Healthy and every pod is Ready |
| `make info` | Prints URLs and where the credentials come from, never the passwords |
| `make argocd-password` | Prints the Argo CD admin password (use `make -s` to keep make's own output out of it) |

`make build-all` runs these steps in order: `vendor`, `kind-cluster`, `namespaces`,
`argocd-install`, `rollouts-install`, `secrets-base`, `kps-install`, `images`, `litellm-install`,
`litellm-keys`, `grafana-token`, `secrets-late`, `holmes-install`, `dryrun-summary-restore`,
`disarm-git-only`, `gitops-bootstrap`, `wait-platform`. Each can be run alone. Notes on the order:

- `disarm-git-only` comes before `gitops-bootstrap`, so Argo CD's first sync already reads the
  disarmed config. It needs the operator clone and skips with a warning without one.
- Secrets are split in two: `secrets-base` needs no running service, `secrets-late` needs Argo CD
  (it mints HolmesGPT's read-only token) and Grafana.
- `images` builds the demo images with the pinned base images and loads them into the kind
  nodes. It skips what is already present.

Other platform targets: `kind-cluster`, `helm-repos`, `argocd-install`, `rollouts-install`,
`kps-install`, `litellm-install`, `holmes-install`, `secrets`, `grafana-token`, `litellm-keys`,
`namespaces`, `gitops-bootstrap`, `dryrun-summary-restore`.

## The operator clone and the operator scripts

The scripts that drive the incident push to the tracked branch. They do it from a separate HTTPS
clone, never from the main checkout:

```bash
make operator-clone
```

The clone lives at `OPERATOR_DIR` (`~/.local/share/argoconna26/operator`). Its credential helper
is `gh auth git-credential`, so it uses your `gh` login, or `GH_TOKEN` when set; pushes never
depend on an SSH agent. Operator git runs without your global git config, so a global
`url.<ssh>.insteadOf` rule cannot turn the remote back into SSH, and each sync checks that
`origin` is the expected URL. `make operator-clone` also installs a pre-commit hook from
`PRECOMMIT_HOOK_SRC`; without it, operator pushes stay refused. Argo CD is driven through
`kubectl` only (the refresh annotation, and reading Application status), so there is no Argo CD
CLI session to expire.

| Target | What it does |
|--------|--------------|
| `make seed-history` | Disarms, then commits the PR-242 timeout change and one harmless docs change. Stops before the bump |
| `make bump` | Bumps the checkout image tag by one patch version (a deploy) |
| `make rearm` | Re-applies the PR-242 timeout, waits for Argo to sync it, then bumps the image. Refuses (exit 7) when already armed |
| `make fix` | Restores the timeout and bumps config-version in one commit |
| `make naive-revert` | Reverts the last image bump: green but wrong. See [03](./03-the-incident.md) |
| `make disarm` | Timeout back to 2000. `IMAGE=vX.Y.Z` also pins the tag and config-version; `GIT_ONLY=1` pushes without waiting for the cluster |
| `make promotion-pr-ensure LEVEL=propose\|act` | Closes any open promotion PR and opens a fresh one |
| `make promotion-record-approval PR=<n>` | After the merge, records who approved in `autonomy.yaml` |
| `make demote` | Lowers the autonomy level by one step |

Each `rearm`, `fix` and disarm posts a `change.merged` event to the timeline with a fresh change
reference. Under `STAGE=1` they print one short line per step, cut to `STAGE_COLS`, with no raw
SHAs, and the machine-readable results (`cause`, `bump`, `change_ref`) go to files under
`.operator/` in the main checkout, which is gitignored. Without `STAGE=1` they print to stdout.

## Resets between runs

| You want | Do |
|----------|----|
| A clean incident again | `make disarm IMAGE=v1.4.1`, then `make rearm` |
| Back to the first-run history | `make disarm IMAGE=v1.4.1`, then `make seed-history`, `make bump` |
| The agent at a lower level | `make demote` (repeat for two steps) |
| Remove a leftover test hook | `make bridge-hooks-clear` |
| A fresh timeline | `POST /seed?reset=true` on cdevents-sim (`seed-history` does this for the checkout history) |
| A fresh cluster | `make rebuild` |

All resets are forward commits. Nothing force-pushes, and the rulesets would refuse it.

## Checks

```bash
make preflight                         # general
make preflight RUNG=3 PREFLIGHT_ARGS="--armed"   # rung 3, with autonomy already at act
```

`scripts/preflight.sh` exits 1 on any FAIL. Sections: tools, context, cluster, nodes, pods,
endpoints, LLM, bridge test hooks, and for rung 3 the operator credential and CODEOWNERS.
Flags: `--armed` (autonomy on the tracked branch must be `act`), `--pre-promotion` (must still be
`propose`), `--job-run` and `--quiet`.

Other checks:

| Target | Checks |
|--------|--------|
| `make lint` | shellcheck over `scripts/*.sh` and `tests/e2e/*.sh` |
| `make consistency` | No tracked file hardcodes a version, namespace, kind image, context or name that `versions.env` or `demo.env` owns |
| `make test-bats` | The script tests (`tests/bats/`): no cluster, no network |
| `make policy-verify` | The Rego unit tests |
| `make policy-check` | Golden-path labels, and with `BASE=` and `HEAD=` the auto-fix rules |
| `make holmes-rbac-check` | The rendered HolmesGPT role is read-only; the allow-list test |
| `make bridge-hooks-check` | Fails while the test-hook Secret exists |
| `make llm-spend` | Live and cumulative LLM spend against the budget |

Python tests run with `uv run pytest -q` inside `bridge/`, `cdevents-sim/` and each `apps/*`. The
bridge's tests make no network calls (GitHub and HolmesGPT are stubbed, and test RSA keys are
generated at test time).

## End-to-end tests

Under `tests/e2e/`, run from the main checkout. They use the real cluster and real GitHub, and
the real model, so they spend LLM budget and open PRs on the repo.

| Script | Covers |
|--------|--------|
| `tests/e2e/slice2.sh` | The incident mechanics: bump aborts, `fix` heals, `rearm`, `naive-revert`; checks pod values by start time |
| `tests/e2e/rung1.sh` | Rung 1: the agent's comment names the cause, cites the change reference, and the incident resolves. `--seed` for the first run, `--rearm` after |
| `tests/e2e/rung2.sh` | Rung 2: promotion PR, merge, one fix PR with two changed lines, merge, Healthy, counted once |
| `tests/e2e/failure-paths.sh` | A guardrail refusal, a HolmesGPT timeout handoff, a rejected PR and a demotion. Takes `refusal`, `timeout`, `reject` |

`tests/e2e/assert.sh` holds shared assertions. Evidence from a run goes to `EVIDENCE_DIR` (default
`.evidence/` in the main checkout, gitignored). There is no end-to-end script for rung 3 yet.

## The rung-3 scheduled job

Rung 3 runs a user-level systemd unit, `argoconna26-rearm.service`: check, then re-arm.

| Target | What it does |
|--------|--------------|
| `make job-install` | Renders and installs the unit. Re-run when the repo path or `PATH` changes |
| `make night` | Starts that unit now (the nightly job, run on demand). `scripts/night.sh night` exits with the unit's own status; through make any failure shows as 2 |
| `make timer-arm AT="YYYY-MM-DD HH:MM"` | Optional: installs a timer for the same unit |
| `make timer-status` | Shows the next trigger |
| `make timer-disarm` | Removes the timer and the job env file |

The unit runs `scripts/preflight.sh 3 --armed --job-run --quiet` and then `scripts/rearm.sh`
directly (not through make, so its status is the script's own: 1 for a failed preflight, 7
when already armed). `preflight 3 --armed` also reads the tracked branch's rules and fails
unless `policy-check` is a required status there. `make night` and `make timer-arm` refuse
before starting anything when the cluster lock is held (exit 5), when autonomy on the tracked
branch is not `act` (exit 6), or when `preflight 3 --armed` fails (exit 9). They then write a
runtime file (`$XDG_RUNTIME_DIR/argoconna26/job.env`, mode 0600, outside the repo) holding
`GH_TOKEN` from `gh auth token`, because `gh` keeps its token in the desktop keyring and the unit
cannot read it. The unit deletes the file when it stops. The unit starts only when you run
`make night` or `make timer-arm` yourself; a timer then fires on its own, but only while the
machine is awake and your session is logged in. Nothing on this path nudges Argo CD after the
merge; it syncs on its own reconciliation. See the [README](../README.md).

## Troubleshooting

| Symptom | Likely cause and fix |
|---------|----------------------|
| A script exits 3 | Wrong kube context. The scripts accept only `kind-argoconna26` |
| A script exits 5 | The cluster lock is held. Wait, or find the holder in `.kube/cluster.lock` |
| `build-all` warns "no operator clone" | Run `make operator-clone`, then `make disarm-git-only` |
| `make rearm` exits 7 | Already armed. Run `make disarm` first |
| The bridge refuses or hands off every incident | A test hook is active: `make bridge-hooks-check`, then `make bridge-hooks-clear` |
| No agent comment | `make bridge-log`; curl `/status` on port 30081 for `holmes_reachable`, `github_token_ok` and the last incident |
| The agent's PR never merges at `act` | `policy-check` is missing or failing on the PR; the fallback gives up after 10 minutes and says so in a comment |
| Argo CD lags behind a merge | Reconciliation is 20 s; the operator scripts annotate the Application to refresh it, and GitHub-side merges may need a refresh |
| LiteLLM `prisma schema out of sync` after install | The migration Job has not finished; `make litellm-install` waits for it |
| First success-rate query after a build is empty | Prometheus needs a couple of scrapes. Wait, then run `make preflight` |
| LLM budget reached | `make llm-spend`; raise `LLM_BUDGET_USD` in `.env` and reinstall LiteLLM |
