# Observability Is a Platform Problem Now: Closing the AIOps Loop with ArgoCD and GitOps

A demo of an AIOps agent that earns the right to act. An Argo CD rollout fails, the platform
records it as CDEvents, an agent investigates read-only, and the result goes back into Git as a
comment, a pull request, or a pull request that merges itself. What the agent may do is itself a
file in Git, and raising it is a reviewed pull request.

## What This Demonstrates

One incident, replayed at three levels of trust (the **trust ladder**):

| Rung | Level | What the agent does | Who acts |
|------|-------|---------------------|----------|
| 1 | `suggest` | Posts its root-cause analysis as a comment on the cause commit (or on the PR that merged it). | A human fixes it. |
| 2 | `propose` | Opens a two-line fix PR with the analysis and evidence in the body. | A human reviews and merges. |
| 3 | `act` | Opens the same PR and turns on auto-merge. It merges only after `policy-check` passes, which GitHub enforces as a required status. | A human reviews afterwards. |

The incident is the same each time. A change lowers a timeout (`UPSTREAM_TIMEOUT_MS`, 2000 to
200) without bumping the pod template's config-version annotation. The next image deploy starts
canary pods that read the new value, the canary fails its success-rate gate, and Argo CD reports
the `checkout` application Degraded. Argo CD Notifications then send the agent a webhook.

The loop being closed:

1. Argo CD and Notifications emit CDEvents (deployed, degraded, resolved) to a timeline.
2. The bridge receives the Degraded webhook, reads the agent's level from Git, and asks
   HolmesGPT for a structured root-cause analysis. HolmesGPT can read the cluster, Argo CD,
   Prometheus and the timeline. It cannot write anything.
3. The bridge checks the answer against guardrails, scans it for personal data and secrets, and
   writes the result to GitHub: a comment, a PR, or a PR with auto-merge.
4. Argo CD syncs the merge, the canary passes, the application is Healthy, and the incident
   resolves on the timeline.

Pages in [docs/](docs/00-index.md) cover each part.

## Architecture

```
  operator (make rearm, fix, ...)                 GitHub: the repo, PRs, comments, rulesets
     | push commits, post change events             ^  ^                       |
     v                                              |  | PR / comment          | Argo CD pulls
 +-----------------+  GET /timeline, /incidents     |  | (only writer)         v
 |  cdevents-sim   |<-------------------+           |  |   +-----------------------------------+
 | (timeline,      |                    |           |  |   |  Argo CD  (ns argocd)             |
 |  stands in for  |<-- CDEvents -------|-----------|--|---|   syncs apps from build/demo      |
 |  a collector)   |   deployed,        |           |  |   |   Notifications -> CDEvents + hook|
 +-----------------+   degraded,        |           |  |   +----------------+------------------+
        ^              resolved         |           |  |                    |        |
        | agent events                  |           |  |      Degraded      | sync   |
        |                               |           |  |      webhook       v        v
 +------+-------------------------------+-----------+--+--+      Rollouts: checkout (canary) --> pricing
 |  bridge (ns aiops)                                     |           ^ loadgen     | metrics
 |   autonomy.yaml -> HolmesGPT -> guardrails -> PII scan |           |             v
 |   -> comment | PR | PR + auto-merge                    |      Prometheus --> Grafana (trust ladder)
 +---------------------+----------------------------------+      (ns monitoring)
                       | POST /api/chat
                       v
 +---------------------------------------+      +-----------------------------+
 | HolmesGPT (ns aiops, read-only RBAC)  |----->| LiteLLM (budget, call log)  |--> model provider
 |  kubectl, Argo CD, Prometheus, /timeline |   +-----------------------------+
 +---------------------------------------+
```

Namespaces: `argocd`, `argo-rollouts`, `monitoring`, `demo` (checkout, pricing, loadgen),
`aiops` (bridge, cdevents-sim, HolmesGPT, LiteLLM and its Postgres). See
[docs/01-architecture.md](docs/01-architecture.md).

## Prerequisites

Tools. Versions marked pinned are checked by `make vendor` against [versions.env](versions.env).

| Tool | Version | Notes |
|------|---------|-------|
| Docker | Recent | Builds the demo images |
| [kind](https://kind.sigs.k8s.io/) | v0.33.0 | Pinned |
| kubectl | v1.37.2 | Pinned |
| kubectl-argo-rollouts plugin | v1.10.0 | Pinned |
| argocd CLI | v3.5.6 | Pinned |
| conftest | v0.71.1 | Pinned |
| gitleaks | v8.30.1 | Pinned |
| bats | 1.14.0 | Pinned |
| shellcheck | Recent | `make lint` |
| Helm | 3.x | Not pinned |
| gh | Recent | Operator login; scopes in [docs/github-setup.md](docs/github-setup.md) |
| jq, yq, envsubst, flock, curl, git, uv, pv | Recent | |
| asciinema, agg | v3.2.1, v1.9.0 | Pinned; recording only |
| systemd (user units) | Any | Only for the rung-3 scheduled job (`make night`) |

**Secrets.** Copy [.env.example](.env.example) to `.env`, mode 0600. It is never committed. The
keys, all blank in the example:

| Key | Used for |
|-----|----------|
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` | LiteLLM's upstream provider keys (the second is optional) |
| `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `LITELLM_DB_PASSWORD` | LiteLLM proxy and its Postgres |
| `LLM_BUDGET_USD` | Per-cluster LLM budget in LiteLLM. Also set a spend limit at the provider |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin login |
| `BRIDGE_WEBHOOK_TOKEN` | Bearer token Argo CD Notifications send to the bridge |
| `HOLMES_API_KEY` | `X-API-Key` HolmesGPT requires from the bridge |
| `GITHUB_APP_ID`, `GITHUB_INSTALLATION_ID`, `GITHUB_APP_KEY_PATH` | The bridge's GitHub App (key file must live outside the repo) |
| `STAGE_APPROVER_LOGIN` | Login that approves promotion PRs on stage |
| `EVIDENCE_DIR`, `PRECOMMIT_HOOK_SRC`, `TOOLS_BIN` | Optional local paths |

**GitHub.** The bridge writes to Git only as a GitHub App, and rulesets box that App in. Create
the App, install it on one repository (your fork), and apply the rulesets as described in
[docs/github-setup.md](docs/github-setup.md).

## Quick Start

Argo CD pulls from GitHub, so the cluster follows what is pushed to the tracked branch
(`TRACKED_BRANCH` in [demo.env](demo.env), `build/demo`). Run it from your own fork: set
`REPO_SLUG`, `BOT_LOGIN` and `PROMOTION_TEAM` in `demo.env`, change the `repoURL` in
`gitops/` and `bridge/deploy/deployment.yaml` to match, and run `make consistency`, which
reports names that disagree.

```bash
cp .env.example .env && chmod 600 .env     # then fill in the keys
make vendor                                # tools present and at the pinned versions
make operator-clone                        # the clone the operator scripts push from
make build-all                             # kind cluster, platform, images, apps (safe to run twice)
make preflight                             # checks; RUNG=1|2|3 for a rung's extra checks
make info                                  # URLs and where the credentials come from
```

`make build-all` pushes a disarm commit before Argo CD first syncs, so a branch left armed never
meets a fresh cluster. It needs the operator clone to do that and skips with a warning without
one. `make rebuild` deletes the cluster and builds it again; `make rm-kind` only deletes it.

## Access

All ports bind to 127.0.0.1.

| Service | URL | Login |
|---------|-----|-------|
| Argo CD | http://127.0.0.1:30080 | `admin`; password from `make -s argocd-password` |
| Grafana | http://127.0.0.1:30030 | `admin`; password is `GRAFANA_ADMIN_PASSWORD` in your `.env` |
| Prometheus | http://127.0.0.1:30090 | none |
| Bridge | http://127.0.0.1:30081 | `/status`, `/metrics`, `/healthz` |
| cdevents-sim | http://127.0.0.1:30082 | `/timeline`, `/incidents`, `/events` |
| LiteLLM | http://127.0.0.1:30400 | master key from your `.env` |

The kind cluster uses its own kubeconfig (`.kube/argoconna26.yaml` in the main checkout), never
your default one. The make targets set it for you; for your own `kubectl`, export
`KUBECONFIG` to that file. The Grafana dashboard is "Trust ladder".

## Demo Flow

Start from a built, healthy cluster at autonomy `suggest`. Follow the bridge in a second
terminal with `make bridge-log`. Details are in [docs/06-operations.md](docs/06-operations.md).

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

## What's Real

**Real**

- The cluster, Argo CD, Argo Rollouts, Prometheus and Grafana are the real components at the
  pinned versions.
- The incident is real behavior. `checkout` reads `UPSTREAM_TIMEOUT_MS` once at startup, calls a
  `pricing` service that takes about 350 ms, and fails requests with 502 when the timeout is
  200 ms. The canary gate is an Argo Rollouts AnalysisRun on a Prometheus query.
- HolmesGPT is the real chart and image, with a real LLM behind LiteLLM. Its role is read-only
  (`get`, `list`, `watch`, no Secrets), proved by `make holmes-rbac-check`. It has no GitHub
  credential and no write path.
- **The bridge is the only writer.** It holds the GitHub App credential. Every agent action is a
  pull request or a comment, never a direct cluster write, and the bridge has no Kubernetes
  RBAC at all.
- The App cannot push to, rewrite or delete the tracked branch, or create promotion branches.
  Rulesets enforce that, not the bridge. `python -m bridge.cli try-direct-push` is the proof.
- Guardrails, the PII scan and the fix builder run on every incident. LiteLLM keeps a log of
  every call and a per-cluster budget.

**Simulated or stood in**

- `cdevents-sim` stands in for a CDEvents collector and its database. It accepts events, keeps
  them in a file, validates them against the vendored CDEvents v0.5.1 schemas, and serves
  `/timeline`. The Argo CD notification templates that produce CDEvents are a template library,
  not part of Argo CD.
- **Change events are written by the operator scripts.** In a real setup a forge or change
  system would send them. GitHub cannot reach a laptop, so `make rearm`, `make fix` and the
  other scripts post a `change.merged` event themselves. It carries only what a forge would send:
  the commit SHA, title, changed files, author, time and a change reference (`CHG-` plus six
  characters). It carries no diagnosis (no key, no old or new value, no mention of
  config-version). The agent has to find those in the ConfigMap, the metrics and Git.
- The HolmesGPT prompt is a single-scenario runbook. It says where to look, not what is wrong.
- The apps carry the OpenTelemetry SDK, but nothing sets an OTLP endpoint, so no traces leave
  them and none are collected. The agent reads metrics, events and Kubernetes and Argo state.
- Time is compressed. Promotion criteria in the promotion PR (a dry-run score bar, weeks at a
  level) are stated there, and the demo waits minutes, not weeks.

**What GitHub enforces and what the bridge enforces**

- *GitHub:* the three standing rulesets (nobody deletes or force-pushes a tracked branch; changes
  to it arrive by pull request, with only a repository admin able to bypass; only an admin
  creates, moves or deletes `promote/*`); and the required `policy-check`
  status. Code-owner review on `aiops/autonomy.yaml`, `policy/` and `.github/` comes on with
  `scripts/github-ruleset.sh apply --with-policy-check` once the promotion-board team exists
  (a plain `apply` also keeps a live required check); with it on, an agent PR that raises
  `aiops/autonomy.yaml` stays blocked until the board reviews it. Until then, the required
  check's auto-fix rule 1 is what denies an agent PR that touches `aiops/autonomy.yaml`,
  `policy/` or `.github/`. `scripts/github-ruleset.sh show` prints which mode is live.
- *The bridge:* at `suggest` it opens no PR; at `propose` it never calls merge or auto-merge, so
  "a human merges" holds there because of the bridge, not a GitHub approval rule. The tracked
  ruleset requires zero approvals on purpose, so that `act` can auto-merge. The bridge also
  checks that `policy-check` succeeded before any merge it makes itself (the fallback and the
  catch-up after a slow auto-merge).
- *The required check's trust boundary:* `policy-check` judges a PR with the policy on the PR's
  base branch, not the copy the PR carries. The workflow itself runs from the PR's merge ref, so
  a PR that edits it could change how it runs. What stops an agent PR doing that: the App has no
  `workflows` permission, so GitHub refuses its commits under `.github/workflows/`, and for the
  agent's PRs auto-fix rule 1 denies any change outside the two fix files. `.github/` is also
  code-owned, which binds once code-owner review is on. The workflow runs every tool outside the
  PR's checkout, so a `conftest.toml` or `yaml.py` in the PR cannot configure the check either.
  See [docs/05-policy.md](docs/05-policy.md).
- The policy sees Git facts only (the diff, the history of the tracked branch, the PR author and
  body). It does not look at the cluster or the model's reasoning.
- Fix-PR outcomes and `policy-check` results on the dashboard are counted by polling GitHub,
  since the App's webhook is inactive.
- Promotion records name the approver's role with a link to the review, or say `admin-bypass`.
  Never a login.
- The PII scanner is deliberately simple: email addresses, common token formats, private-key
  headers and non-loopback IP addresses.
- The rung-3 job is a user systemd unit. In rehearsal and on stage it is started on demand with
  `make night`, which runs the same unit and environment a timer would.

Follow-up for a real platform: hash the config into the pod template (for example Kustomize's
`configMapGenerator`), so a config change rolls the pods by itself and this incident cannot
happen.

## Repo Structure

| Path | What it is |
|------|-----------|
| `Makefile`, `versions.env`, `demo.env`, `.env.example` | Entry points, pinned versions, names and ports, secret keys |
| `cluster/` | kind configuration |
| `platform/` | Helm values and manifests: Argo CD (with Notifications), Rollouts, kube-prometheus-stack, HolmesGPT, LiteLLM, the Grafana dashboard |
| `gitops/` | The app-of-apps root and one Application per component |
| `apps/` | `checkout` (Rollout, config, analysis), `pricing`, `loadgen` |
| `bridge/` | The bridge service (FastAPI): webhook, pipeline, guardrails, PII scan, templates, GitHub forge |
| `cdevents-sim/` | The timeline service and the vendored CDEvents schemas |
| `aiops/autonomy.yaml` | The agent's current autonomy level |
| `policy/` | Rego: golden-path labels, auto-fix rules, and the Git facts extractor |
| `.github/` | `CODEOWNERS` and the `policy-check` workflow |
| `scripts/` | Operator scripts, GitHub rulesets, preflight, secrets, the rung-3 job |
| `tests/` | `bats/` for scripts, `e2e/` for runs against a real cluster and GitHub |
| `docs/` | These docs and [github-setup.md](docs/github-setup.md) |

Tests: `make test-bats` (scripts), `make policy-verify` (Rego), `cd bridge && uv run pytest -q`
(bridge; no network calls), and the same in `apps/*` and `cdevents-sim`. `make lint` runs
shellcheck over `scripts/` and `tests/e2e/`. `make consistency` fails when a tracked file
hardcodes a version or name that `versions.env` or `demo.env` owns.

## Version Pins

From [versions.env](versions.env). Nothing else in the repo hardcodes these.

| Component | Version |
|-----------|---------|
| kind / node image | v0.33.0 / `kindest/node:v1.36.4` (digest-pinned) |
| kubectl | v1.37.2 |
| Argo CD (chart) | v3.5.6 (10.11.6) |
| Argo Rollouts (chart) / plugin | v1.10.1 (2.43.8) / v1.10.0 |
| kube-prometheus-stack (chart) | 92.14.0 |
| Prometheus / Prometheus Operator | v3.15.1 / v0.94.2 |
| Grafana | 13.2.4 |
| HolmesGPT (chart) | 0.45.0 |
| LiteLLM (chart and image tag) | 1.106.4 / v1.106.4 |
| LiteLLM Postgres image | `postgres:16.11-alpine` (digest-pinned) |
| conftest | v0.71.1 |
| gitleaks | v8.30.1 |
| bats | 1.14.0 |
| CDEvents spec | v0.5.1 |
| Python base image / uv image | `python:3.13-slim` / `ghcr.io/astral-sh/uv:0.13.6` (digest-pinned) |
| prometheus-client / OpenTelemetry SDK | 0.26.0 / 1.45.1 |
| Grafana Infinity plugin | 4.1.3 |
| asciinema / agg | v3.2.1 / v1.9.0 |
| demo-magic | commit `142f0e7` |

The LLM models are set in `platform/litellm/config.yaml` (aliases `rca` and `judge`).

## References

- [Argo CD](https://argo-cd.readthedocs.io/), [Notifications](https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/)
- [Argo Rollouts](https://argo-rollouts.readthedocs.io/) and its Prometheus analysis provider
- [CDEvents](https://cdevents.dev/) specification v0.5.1
- [HolmesGPT](https://holmesgpt.dev/)
- [LiteLLM](https://docs.litellm.ai/)
- [GitHub repository rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets) and [CODEOWNERS](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners)
- [Open Policy Agent / Rego](https://www.openpolicyagent.org/docs/latest/policy-language/) and [conftest](https://www.conftest.dev/)
- [kind](https://kind.sigs.k8s.io/)

<!-- credits: held -->

## License

MIT. See [LICENSE](LICENSE).
