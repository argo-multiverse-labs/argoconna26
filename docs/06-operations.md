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

## Running the rungs by hand

What the scene and rung scripts do, step by step. Start from a built, healthy cluster at autonomy
`suggest`, and follow the bridge in a second terminal with `make bridge-log`.

### Rung 1: suggest

```bash
make seed-history      # first run: disarm, then commit the PR-242 timeout change and a docs change
make bump              # bump the image tag: the deploy that gets aborted
# later runs: make rearm   (re-applies the timeout, then bumps)
```

The canary fails its gate, Argo CD reports Degraded, and the bridge comments on the cause commit
with the root cause, evidence, the change reference from the timeline, and what a human should
change. Then `make fix` restores the timeout and bumps config-version in one commit, and the
application goes Healthy.

### Rung 2: propose

```bash
make promotion-pr-ensure LEVEL=propose   # opens a promotion PR that changes only aiops/autonomy.yaml
# a promotion-board member approves and merges it on GitHub
make promotion-record-approval PR=<number>
make rearm                               # the same incident
```

The agent opens one fix PR with two changed lines (the timeout and config-version). A human
reviews and merges it, Argo CD syncs, and the application recovers.

### Rung 3: act

At `act` the bridge enables GitHub's auto-merge on its fix PR. GitHub merges it once the required
`policy-check` passes. If the check passed and the PR is still open 30 s later
(`ACT_AUTOMERGE_GRACE_S`), the bridge merges it itself at the PR's head SHA; GitHub enforces the
required check on that merge too. If auto-merge cannot be enabled at all, the bridge waits for
the check and merges only on `success`. The trigger is a scheduled job: one user-level systemd unit that runs the
rung-3 preflight and then `rearm`.

```bash
make promotion-pr-ensure LEVEL=act
make job-install        # installs the user unit argoconna26-rearm.service
make night              # starts that unit now: preflight, then rearm
```

From the trigger to Healthy no human acts: the agent opens the PR, `policy-check` passes, GitHub
merges it, and Argo CD syncs on its own reconciliation (nothing nudges it). A person reviews
afterwards. `make night` is the nightly job run on demand; no timer is armed unless you run
`make timer-arm`. `scripts/night.sh night` returns the job's own exit code (make reports any
failure as 2).

Measured on the kind cluster (one run, no Argo refresh): 74 s from typing `make night` to the
PR, 53 s from the PR to the merge, 69 s from the merge to Healthy. PR to merge depends on
GitHub's auto-merge and ranged from 18 s to 200 s across earlier runs, which is why the bridge
now merges itself after the grace period.

The end-to-end tests: `tests/e2e/rung3.sh` runs the rung from the pre-promotion state;
`tests/e2e/overnight-verify.sh SINCE=... UNTIL=...` checks a run after the fact (the job started
the rearm, the bot merged its own PR with no reviews, the check passed with the auto-fix rules
applied); `tests/e2e/policy-negative.sh` opens App-authored PRs that should fail the check. Those
test PRs are titled `[policy negative test]` and labelled `policy-negative-test`: the operator
opened them with the agent's identity, the agent did not.

### Going back down

`make demote` lowers the level by one step with a forward commit. `make disarm` puts the timeout
back to 2000 (`IMAGE=vX.Y.Z` also pins the image tag).

## Resets between runs

`scripts/reset.sh` puts the demo back at a rung's starting state. Every step is a forward commit
or a condition wait, nothing reads the time of day, and it runs under the cluster lock.

| Target | Ends at |
|--------|---------|
| `make reset-rung-1` | Disarmed, autonomy `suggest`, PR-242 history seeded; its cause and change reference saved for `demo-rung-1` |
| `make reset-rung-2` | Disarmed, `suggest`, a fresh `propose` promotion PR open |
| `make reset-rung-3` | Disarmed, `propose`, a fresh `act` promotion PR open. From `suggest` it opens the `propose` promotion PR and exits 6, because a reset never raises the level |
| `make reset-demo` | The rung-1 reset plus a re-seeded timeline. Use it before a full rehearsal |

In order, a reset: syncs the operator clone; labels every `agent/*` PR `demo-reset` (so the
dashboard's counts start at 0) and closes the open ones; disarms with the stable image pinned;
lowers autonomy to the rung's level by `demote` only; clears the notified annotation on the
checkout Application; opens the promotion PR for rung 2 or 3; clears bridge test hooks and
restarts the bridge; waits for checkout and pricing Healthy; prints the elapsed seconds. Measured:
`reset-rung-1` about 22 s; `reset-demo` from an armed, Degraded state 142 s (disarm takes two
commits when the pods read 200).

Other resets:

| You want | Do |
|----------|----|
| A clean incident again | `make disarm IMAGE=v1.4.1`, then `make rearm` |
| The agent at a lower level | `make demote` (repeat for two steps) |
| Remove a leftover test hook | `make bridge-hooks-clear` |
| A fresh timeline | `POST /seed?reset=true` on cdevents-sim (`reset-demo` does this) |
| A fresh cluster | `make rebuild` |

All resets are forward commits. Nothing force-pushes, and the rulesets would refuse it.

## The rung scripts

`make demo-rung-1`, `demo-rung-2` and `demo-rung-3` run a rung as it is shown on stage, with
typed commands (demo-magic, pinned by `DEMO_MAGIC_SHA`) and lines that fit the stage terminal
(`DEMO_COLS`, below). Start each from its reset.

| Script | Starts from | Does |
|--------|-------------|------|
| `demo-rung-1.sh` | `reset-rung-1` | `make bump`, Degraded, the agent's comment on the cause commit, `make fix`, Healthy, resolved |
| `demo-rung-2.sh` | `reset-rung-2` | Checks the promotion PR, waits for its merge, records the approval, `make rearm`, the fix PR, its merge, Healthy. If the fix PR is closed it demotes, fixes by hand and shows the rejected count |
| `demo-rung-3.sh` | `reset-rung-3` and the `act` promotion | Runs `make night` ("running the nightly job now"), the bot's PR, `policy-check`, the merge by the bot, Healthy, then opens the PR and its Checks tab. It holds no lock, merges nothing and does not nudge Argo CD |

Settings (see `scripts/demo-common.sh`): `TYPE_SPEED`, `NO_WAIT=true` (no pauses; each script then
ends with assertions, and rung 3 runs `overnight-verify.sh` over its own window), `DEMO_COLS` and
`DEMO_OPEN` (below). Under `NO_WAIT` rung 3 fails when `policy-check` fails.
`DEMO_AUTOMERGE_FOR_TEST` and `DEMO_REJECT_FOR_TEST` let rung 2 run unattended in tests. A refusal, a PII block or a handoff by the agent is shown as a feature.

Measured (one session): rung 1 trigger to comment 52 to 72 s; rung 2 merge to Healthy 50 to 51 s;
rung 3 PR to merge 57 to 140 s and merge to Healthy 55 to 66 s, 210 s from `make night` to Healthy.

### The stage terminal: width, browser, what is shown

Both settings go in `.env` (see `.env.example`); a value set on the command line wins over `.env`.

- `DEMO_COLS`: the width of the demo terminal. Narration wraps to it, and the scene and speaker
  bars and title cards fill it. Blank (the default): the terminal's own width, at most 78; 78 when
  the output is not a terminal (a pipe; the tests set 72). A 28 pt font on a 1080p projector is
  about 80 columns. Set it when the stage pane is narrower than the window. `STAGE_COLS` in
  `demo.env` (30) is a different budget: the operator scripts' one-line beats and the bridge's
  stage log, which must match `bridge/deploy/deployment.yaml`; leave it alone.
- `DEMO_OPEN`: the command that opens a URL, split into words. Blank: `xdg-open` (`open` on
  macOS), the OS default browser. To use the Chrome window that is already open, set
  `DEMO_OPEN=google-chrome`, which opens a new tab there and returns (on macOS
  `DEMO_OPEN=open -b com.google.Chrome`); `DEMO_OPEN=true` opens nothing. The scenes open only
  pages that are new on stage: the RCA comment, the promotion and fix PRs, the PR's checks,
  `policy/autofix.rego`. Argo CD and Grafana are never opened: keep them on their own tabs all
  talk. The tests point `DEMO_OPEN` at a logger.
- Where to look is on screen. Before the audience should switch to the browser, a `▶` line names
  the tab and what to look at ("▶ Browser, Grafana: the top panel"); for a new page it also opens
  it. `look WHERE [URL]` in `scripts/demo-common.sh` prints it.
- What runs out of view is on screen. A command the speakers type is typed at the prompt
  (`make bump`, `make fix`, `make demote`), and the prologue reads PR-242's timeout from the live
  ConfigMap (`kubectl get configmap checkout-config ... | grep TIMEOUT`). A step a script takes
  for them is typed too, then run:
  `scripts/promotion-pr.sh verify|record-approval|ensure ...` and
  `tests/e2e/overnight-verify.sh SINCE=... UNTIL=...`. Plumbing with no command worth reading is
  one plain line starting `›` ("› asking Argo CD to refresh checkout now"; the test hooks say
  so too). `shown DISPLAY CMD...` and `note TEXT` in `scripts/demo-common.sh` do this.
- The prompt follows the speaker: after the On-call SRE's bar the prompt is `[SRE]$`, so the
  human fix reads `[SRE]$ make fix`.

## Scenes and demo-full

The talk's linear flow (the README's Demo Flow) wraps the rung scripts in scenes:
`demo-cold-open`, `demo-prologue`, `demo-scene-1` to `demo-scene-3`, `demo-epilogue` and
`demo-close`, and `make demo-full` runs them in order with no reset between them.
From scratch, `make build-all` creates the kind cluster and the stack first (`stage-day.sh morning`
stops with that hint when there is no cluster). `scripts/stage-day.sh morning` leaves the start
state, including the open `propose` promotion PR.

- Scenes 1 to 3 call the rung scripts' bodies, so every failure branch above carries over. Inside
  a scene, a branch that ends the rung early (a handoff, no fix PR, `policy-check` left for
  review) exits 10, and `demo-full` stops there and returns it. A refusal or PII block ends after
  the human fix with exit 0, so the talk goes on.
- After a stop, `demo-full` prints the next step (two short lines), so the
  clip plays and the later scenes stay live. After a stop in scene 1 or 2: `make
  reset-to-scene-(N+1)` while the clip plays (68 s measured for scene 2), then `make
  demo-scene-(N+1)`. After a stop in scene 3 (exit 10, or exit 6 below `propose`): `make
  demo-epilogue && make demo-close`; the epilogue's `make demote` takes autonomy back to
  `suggest`. After a stop in the epilogue: `make demo-close`. Starting the next scene without its
  reset fails: after a scene-1 stop checkout is still armed, and scene 2's `make rearm` refuses
  with exit 7.
- Scene 2 opens the `act` promotion PR at its end when the level is `propose`. Scene 3 uses it,
  or opens one; below `propose` (after an on-stage reject and demote) it exits 6: play the
  recording.
- In scene 3 `make night` is typed first and the teaching narration runs while the job re-arms
  and the agent works. The verifier's PASS lines print on stage and are saved to
  `.operator/last-verify`; the epilogue replays them, then demotes back to `suggest` (two steps
  from `act`).
- `DEMO_PACE=talk` stops for Enter at `scene_break`, `fourth_wall` and `speaker_beat`, and after
  each line of narration, so the speaker says a line as it appears and the audience never reads
  ahead. Typed commands and waits never stop: the agent, the canary and the nightly job carry on
  while the speakers talk. `DEMO_STEP=section` types a whole narration section without stopping
  (the old pace). `DEMO_PACE=auto` sets `NO_WAIT=true` and never reads stdin.
- Narration: `narrate SCENE KEY` prints the `[KEY]` section of `narration/<scene>.txt` as comment
  lines. The section's lines are joined and re-flowed to the terminal width: whole sentences share
  a line while they fit, so the file's own line breaks do not matter; a blank line inside a
  section starts a new paragraph. A header `[KEY]` is the Platform Engineer's, `[KEY] sre` the
  On-call SRE's and `[KEY] both` the two together; each prints under that character's prompt, and
  in a scene that character keeps the floor (the prompt stays theirs) until the next bar.
  The directory is local and not in the repository; without it the scripts print no narration
  and work the same. `NARRATION_DIR` points elsewhere.
- Who is talking: each character has a bold, colour-coded prompt (`[PE]$`, `[SRE]$`, `[ALL]$`),
  a `speaker_beat` is a full-width bar in that colour, and a scene starts between two `═` bars.
  `DEMO_THEME=light` (the default, for the light stage terminal) or `DEMO_THEME=dark` picks the
  colours.
- In a real terminal (`STAGE_FX=1`, the default when stdout is a terminal) the scenes also pin a
  trust-ladder bar to the top line (the story's clock and `suggest ▸ propose ▸ act` with the
  current rung lit), show a spinner with the seconds so far while they wait, and mark PASS, FAIL,
  refused and handoff lines with `✓`, `✗` and `↪`. The cold open and the close open with a
  title card. Piped or under the tests (`STAGE_FX=0`) the output is the plain text.
- `make reset-to-scene-N` is the matching reset (`0` is `reset-demo`). `reset-rung-1` and
  `reset-demo` close any promotion PR a scene run left open.

Measured (one run, kind, real model): `stage-day.sh morning` 41 s; `DEMO_PACE=auto make
demo-full` 8 min 54 s of machine time (cold open and prologue about 2 s, scene 1 105 s, scene 2
177 s, scene 3 241 s, epilogue and close 9 s); `reset-to-scene-2` 68 s, then `demo-scene-2`
201 s.

## Recording

`make record-rung-1|2|3`, `make record-scene-1|2|3` and `make record-full` run the matching
script under `asciinema` at `DEMO_COLS` (default 78) x `STAGE_ROWS` and write
`recordings/<rung-N|scene-N|full>-<timestamp>.cast` (gitignored). `RECORD_CMD` replaces the command.
`make gif CAST=<file>` converts a cast with `agg` (the newest cast by default).

## Scoring the agent: the dry-run harness

`make dry-runs N=20 BATCH=5` (`scripts/dry-runs.sh`, `bridge/src/bridge/dryrun.py`) runs scored
investigations against the real cluster and HolmesGPT without posting to GitHub or emitting events.
It needs autonomy `suggest`, the main checkout, and the cluster lock, and it is never run during a
rung-3 window. Before each batch it disarms to the stable tag, re-arms, and waits for the abort and
for the live bridge to finish, so each batch is a fresh incident (the same v1.4.1 to v1.4.2 bump
the stage shows). With N=20 and BATCH=5 that is four incidents with five runs each.

- **Scoring.** `score.py` checks the cause SHA (a unique short prefix counts), the config key and
  both values, the policy result of the fix it would build, that the answer is free of personal
  data, and that the answer cites the timeline's change reference (`delivery_context_ok`).
  `root_cause_matched` is the SHA, key and values together. `judge.py` has a second model grade the
  explanation as correct, partial or wrong.
- **Models.** The agent is `anthropic/claude-sonnet-5-5` behind the `rca` alias at temperature 1.
  The judge is the `judge` alias and is sent no temperature or other sampling parameter, because
  that model rejects them.
- **Publishing.** Only a full run (N at least the denominator of `PROMOTION_SCORE_BAR`, 20/20, or
  `DRYRUNS_PUBLISH=1`) writes `.dryruns/summary.json` and the ConfigMap `dryrun-summary`. A smaller
  run writes `summary-smoke-<time>.json` and publishes nothing. `make dryrun-summary-restore`
  re-applies the file (`build-all` runs it).
- **Ablation.** `ABLATE_TIMELINE=1` reinstalls HolmesGPT with the `cdevents-timeline` toolset off
  (`make holmes-install HOLMES_SET=...`), runs the batches, writes `results-ablation-<time>.json`
  and no summary, and restores the toolset on exit.
- **Cost.** Each batch lets the live bridge post one `suggest` comment on the re-armed incident.

**Results.** The full run (11-02): 20/20 matched the root cause and every other check, across 4
incidents with 5 runs each, model `anthropic/claude-sonnet-5-5` at temperature 1. The judge rated
20 correct; the change reference was cited 20 of 20 times; 0 PII blocks, 0 refusals; answer time
p50 28 s, p95 37 s. Confidence ranged 0.70 to 0.90, so the threshold stays 0.7 (one answer sat on
it). The ablation ran twice on one incident: the change reference was cited 0 of 2 times and the
cause commit named 0 of 2 times, with the right key and values both times. Two runs on one
incident say nothing about cause; treat it as a check that the scorer notices the missing
timeline. On a slide: "20/20 across 4 incidents, 5 runs each, at temperature 1".

## Stage day

`scripts/stage-day.sh` prints and times each step, stops at the first failure and at every human
step (it reads one line from stdin; EOF stops, so an unattended run never merges). Run it from the
main checkout. Exit codes: 0 done, 1 a step failed, 2 usage, 3 stopped at a human step.

| Command | Does |
|---------|------|
| `scripts/stage-day.sh morning` | Reset, `preflight 1` with a full dry-run score required, the LLM budget (at least `STAGE_LLM_MIN_REMAINING_USD`, default 2.00), `gh` auth, the job unit current, `preflight 3` |
| `scripts/stage-day.sh arm-rung-3 [--admin]` | `reset-rung-3` (from `suggest`: merge the `propose` promotion, record it, reset again), `preflight 3 --pre-promotion`, the human step to approve the `act` promotion PR, merge (`--admin` is logged as `admin-bypass`), record the approval, `preflight 3 --armed` |

The morning check requires a published score from a full run (the 20-run score is published, so
it passes; on a fresh cluster run `make dry-runs N=20 BATCH=5` first). Steps and timings are saved
under `EVIDENCE_DIR`. Both subcommands have been run on the cluster (morning about 97 s,
`arm-rung-3 --admin` about 98 s); the human step merges with a promotion-board approval, or with
`--admin`, which is recorded as `admin-bypass`.

## Retargeting the tracked branch

`make retarget BRANCH=main` (`scripts/retarget.sh`) moves what Argo CD, the bridge and the rulesets
follow, under the cluster lock, stopping at the first failure and resuming on a re-run. It moves
forward only: the new branch must contain the current tip. Before changing anything it refuses a
branch that the live rulesets do not already protect, one with a higher autonomy level, or one that
changes code-owned paths. Then: one commit rewriting every `targetRevision`, `TRACKED_BRANCH` in
`demo.env` and the bridge Deployment, and `RULESET_BRANCHES`; re-apply the root Application and wait
for every Application to follow; wait for the bridge rollout; re-apply the rulesets and read them
back; open a fresh promotion PR against the new base. Rehearsed live on 11-03, `build/demo` to
`main`; it needs a ruleset apply, so it waits for a go-ahead.

## Forks

`make configure-fork REPO_SLUG=you/repo BOT_LOGIN=app[bot] PROMOTION_TEAM=@you/team` rewrites the
names (`scripts/configure-fork.sh`; offline, idempotent). `make consistency` then checks that
nothing still names the old values. See [07](./07-setup.md#run-it-from-your-own-fork).

## Checks

```bash
make preflight                         # general
make preflight RUNG=3 PREFLIGHT_ARGS="--armed"   # rung 3, with autonomy already at act
```

`scripts/preflight.sh [RUNG] [flags]` exits 1 on any FAIL. Without a rung it runs the platform
sections: tools, context, cluster, nodes, pods (every namespace), endpoints, apps (every Argo CD
Application Synced and Healthy), bridge (Deployment ready; `/status` has `github_token_ok`,
`holmes_reachable` and `dry_forge` false), bridge test hooks, holmes (the read-only `can-i` checks),
LLM and local (pre-commit hooks, one kube context, free disk).

With a rung it adds:

| Section | Rungs | Checks |
|---------|-------|--------|
| `fleet` | 1, 2, 3 | Every Ready checkout pod reports 2000, the 1 m success rate meets the SLO, no checkout pod has restarted; rungs 1 and 2 also need the stable image |
| `github_admin` | 2, 3 (not under `--job-run`) | Repo settings, the three rulesets, the required `policy-check`, the team's access, the labels, the stage approver's membership (`STAGE_APPROVER_LOGIN` in `.env`) |
| `github_runtime` | 1, 2, 3 | The operator credential, the autonomy level for the rung and mode, the promotion state, CODEOWNERS, the required `policy-check` when armed, the App's installation permissions |
| `job` | 3 (not under `--job-run`) | The rung-3 unit is installed, current, with a PATH that resolves the pinned tools; no stale `job.env`; with `--armed`, `cluster_lock` is free |

Promotion state: rung 2 needs autonomy `suggest` and exactly one open `propose` promotion PR;
`3 --pre-promotion` needs `propose` and exactly one open `act` promotion PR; `3 --armed` needs `act`
with `approved_by` recorded (an `admin-bypass` approval is a WARN so the slide can say so).

A `dryrun` section checks the published score: it fails when `.dryruns/summary.json` is not a full
run (N below the bar, or the incident and run counts do not multiply to N) or differs from the
ConfigMap, and it warns "pending" when neither exists. `PREFLIGHT_REQUIRE_SCORE=1` (stage-day
morning sets it) turns pending into a failure.

Checks that need the promotion-board team or code-owner review (the code-owner rule itself, the
team's permission, the approver's membership, the App's permissions) are failures by default
(`PREFLIGHT_L5B=1`). On a fork that has not created its team and run the full
`scripts/github-ruleset.sh apply` yet, `PREFLIGHT_L5B=auto` prints them as `WARN ... (deferred to
L5b)` until the code-owner rule is live; the rule is read from the live rules, and an unreadable
read is a failure, not a deferral. `PREFLIGHT_L5B=0` always defers them.

Flags: `--armed` (autonomy on the tracked branch must be `act`), `--pre-promotion` (must still be
`propose`), `--job-run` (GH_TOKEN is the credential; skips `github_admin` and `job`) and `--quiet`.

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
| `tests/e2e/rung3.sh` | Rung 3 from the pre-promotion state: promotion to `act`, `make night`, one bot PR that merges with no human action, sync, Healthy, then `overnight-verify.sh` over the run window. Leaves autonomy at `act` (`make demote` lowers it) |
| `tests/e2e/overnight-verify.sh` | Checks a rung-3 run after the fact for `SINCE=... UNTIL=...`: only the job's rearm commits, one bot PR merged by the bot with no reviews, `policy-check` passed with the auto-fix rules applied, the metric rose, the merge deployed, the incident resolved |
| `tests/e2e/policy-negative.sh` | Opens App-authored PRs that break a rule (image change, edits to the auto-fix policy, golden path, workflow, autonomy, a planted `conftest.toml` or `yaml.py`) and checks each one fails `policy-check`, shows `BLOCKED` and stays unmerged. The workflow edit is refused by GitHub before a PR exists. For the autonomy case the code-owner block is also expected (the review request goes to the promotion board) |

`tests/e2e/assert.sh` holds shared assertions. Evidence from a run goes to `EVIDENCE_DIR` (default
`.evidence/` in the main checkout, gitignored). PRs the tests open are labelled `demo-reset` or
`policy-negative-test`, so the dashboard does not count them.

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
`GH_TOKEN` from `gh auth token`. `gh` keeps its token in the desktop keyring, which a user unit
can read only while the keyring is unlocked; the file means a timer run doesn't depend on that.
The unit deletes the file when it stops. The unit starts only when you run
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
| The agent's PR never merges at `act` | `policy-check` is missing or failing on the PR. The bridge waits up to 10 minutes for the check; when it had to wait itself (auto-merge could not be enabled) it says so in a comment. A failing check gets one comment from the reconciler |
| Argo CD lags behind a merge | Reconciliation is 20 s; the operator scripts annotate the Application to refresh it, and GitHub-side merges may need a refresh |
| LiteLLM `prisma schema out of sync` after install | The migration Job has not finished; `make litellm-install` waits for it |
| No Rollout tab on the `checkout` Rollout in Argo CD | The extension download failed when `argocd-server` started (no network). `kubectl -n argocd logs deploy/argocd-server -c rollout-extension`, then restart `argocd-server` once online |
| The ArgoCD or Argo Rollouts dashboard is empty | Check the Prometheus targets page (port 30090) for `argocd-*-metrics` and `argo-rollouts-metrics`. The ServiceMonitors come from the `dashboards` Application, so it must be Synced |
| First success-rate query after a build is empty | Prometheus needs a couple of scrapes. Wait, then run `make preflight` |
| LLM budget reached | `make llm-spend`; raise `LLM_BUDGET_USD` in `.env` and reinstall LiteLLM |
