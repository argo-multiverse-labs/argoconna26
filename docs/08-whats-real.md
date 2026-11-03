# 08. What's Real

What in the demo is the real thing, what is simulated or stood in, and which rules GitHub
enforces versus the bridge. The [README](../README.md#whats-real) has the short version.

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
  status. Code-owner review on `aiops/autonomy.yaml`, `policy/` and `.github/` is on, owned by the
  promotion-board team, so an agent PR that raises `aiops/autonomy.yaml` stays blocked until the
  board reviews it. The required check's auto-fix rule 1 also denies an agent PR that touches
  those paths. `scripts/github-ruleset.sh live-mode` prints which mode is live.
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
  code-owned, and code-owner review is on, so the promotion board must review it. The workflow runs every tool outside the
  PR's checkout, so a `conftest.toml` or `yaml.py` in the PR cannot configure the check either.
  See [docs/05-policy.md](./05-policy.md).
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
