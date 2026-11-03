# 04. The Bridge and HolmesGPT

## Overview

Two components, split by what they may do:

- **HolmesGPT** investigates. It can read the cluster, Argo CD, Prometheus and the delivery
  timeline. It holds no GitHub credential and its Kubernetes role cannot write.
- **The bridge** decides what to do with the answer and does it. It is the only component with a
  Git-write credential, and it uses that credential only to open pull requests and post comments.

The model's answer is treated as untrusted input. The bridge normalizes it, checks it against Git,
scans it, and only then writes anything.

## The bridge

`bridge/` is a FastAPI service run by a single asyncio worker.

| Endpoint | Purpose |
|----------|---------|
| `POST /hooks/argocd` | The Degraded webhook. Bearer token (`BRIDGE_WEBHOOK_TOKEN`), compared in constant time, checked before the body is read. An empty configured token rejects everything (fail closed). Returns 202 queued, 202 duplicate, 401, or 422 for a malformed body |
| `GET /status` | The last level seen, queue depth, last incident and outcome, whether HolmesGPT and the GitHub token are reachable, `dry_forge`, and whether a test hook is active |
| `GET /metrics` | Prometheus metrics |
| `GET /healthz` | Liveness |

Background tasks: the worker (one incident at a time), a status refresher (every 60 s: GitHub
token, HolmesGPT readiness, and the touchpoints gauge from `autonomy.yaml`), and the fix-PR
reconciler (every 30 s). On startup it rebuilds its list of seen incidents from the open
`agent/*` PRs, so a webhook replay after a restart does nothing.

**Idempotency.** One incident per app and synced revision (`checkout@<revision>`). A replay is
acknowledged and ignored. While a fix PR is open for the app, another degraded revision gets one
pointer comment on that PR and no second PR. The fix branch is named
`agent/<app>-<cause7>-<revision7>`, so a second PR for the same revision cannot be created. The forge layer refuses any branch
outside `agent/<name>` before it makes a call.

### The pipeline

```
 webhook --> read autonomy.yaml --> prompt --> HolmesGPT /api/chat --> RCA
         --> guardrails --> render --> PII scan --> comment | PR | PR + auto-merge
         --> CDEvents (analysis completed, change created, agent action)
```

Each step prints a short stage line (`▸ guardrails: passed`) at the stage terminal's width
(`STAGE_COLS`). `make bridge-log` follows them.

**Where the suggest comment goes.** On the cause commit's own PR when it has one: a PR merged
into the tracked branch that contains the commit. Otherwise on the commit. An open PR that
merely contains the commit (a test PR branched after it, say) never gets the comment.

**Act and auto-merge lag.** At `act` the bridge turns on GitHub's auto-merge, then keeps
reading `policy-check`. If the check passed and the PR is still unmerged
`ACT_AUTOMERGE_GRACE_S` (30 s) later, the bridge merges it itself over REST, pinned to the head
SHA. GitHub still enforces the required check on that merge. Once, auto-merge took 3 minutes
after the check passed. If GitHub merges first, the bridge's merge is refused and that's not an
error. `0` turns the catch-up off; a dry forge never does it.

### The prompt

The prompt (`bridge/src/bridge/prompt.py`) is a single-scenario runbook. It names where to look
and not what is wrong:

1. Read the Rollout, its status message, canary steps and the failed AnalysisRun measurements.
2. In Prometheus, read the config gauge by pod over the incident window and group pods by start
   time against the sync time, not by canary versus stable.
3. Read the ConfigMap and compare it with what each pod reported.
4. Query the delivery timeline for the change that introduced the config value, and note its
   change reference, commit SHA and how long before the abort it landed.
5. Check whether that change also bumped the config-version annotation, by comparing ReplicaSets
   and the manifests at the synced revision.
6. Read the owner and SLO labels and say whose SLO was at risk.

The window is 10 minutes before the webhook to 1 minute after; the timeline lookback is 72 hours.
The prompt tells the model never to include IP addresses, email addresses, tokens or Secret
values, and not to read Kubernetes Secrets.

### The answer's shape

The bridge sends a strict JSON schema (`response_format`) and validates the reply again
(`bridge/src/bridge/rca.py`). Every field is required:

| Field | Meaning |
|-------|---------|
| `root_cause` | One sentence |
| `cause_commit_sha` | The commit that introduced the bad value (not necessarily the synced one) |
| `evidence` | One to five items, each beginning with its source |
| `delivery_context` | One sentence from the timeline: change reference, short SHA, lead time |
| `confidence` | 0 to 1 |
| `proposed_patch` | `file`, `key`, `from`, `to`: the config value to restore |

The config-version bump is not in the patch. The bridge adds it.

### HolmesGPT client

`bridge/src/bridge/holmes.py` calls `POST /api/chat` with `X-API-Key` and `Accept: application/json`
(HolmesGPT hands request headers to its shell tools and refuses to run them if a header holds a
shell metacharacter, so the default `Accept: */*` would break every cluster read). The wall-clock
timeout is `HOLMES_TIMEOUT_S` (115 s). On timeout or an unusable answer the bridge posts a fixed
handoff sentence on the synced revision and does nothing else. No model text is posted on that
path.

## Guardrails

`bridge/src/bridge/guardrails.py` first normalizes (a 7-character SHA, upper case, `200` versus
`"200"`, `./apps/...` all become canonical), so a correct answer is never refused for its
formatting, then runs every check so that every refusal is reported. Any forge error fails closed.

| Reason | Refused when |
|--------|--------------|
| `low_confidence` | `confidence` is below `CONFIDENCE_THRESHOLD` (0.7) |
| `cause_not_in_history` | The cited commit is not a known commit, or is neither in the Argo history nor an ancestor of the synced revision that changed this key in this file. A full SHA GitHub doesn't know is first matched to the one Argo history revision it shares 7+ leading characters with (models mistype the tail); two candidates are refused |
| `file_not_allowed` | The patch file is outside the allow-list (`apps/*/config/*.yaml`), is absolute or has `..` |
| `key_not_found` | The key is not in a ConfigMap's `data` in that file at the tracked branch |
| `from_mismatch` | The file's current value is not the answer's `from` |
| `patch_failed` | All of the above pass, but no safe two-line edit can be built |

A refusal is posted as a comment (on the cause commit once verified, otherwise on the synced
revision, so a wrong answer never lands on an innocent commit) and counted in
`aiops_guardrail_executions_total{reason}`. No PR is opened.

## The fix builder

`bridge/src/bridge/patch.py` is deterministic. The model names the change; the bridge writes it as
a line-level edit so comments, key order, quoting and line endings survive. It changes exactly two
values: the config key, and the config-version annotation on the pod template, plus one. Then it
re-parses both files and fails closed unless the result equals the original with only those
values changed. Both files are read at one tracked-branch SHA, which becomes the fix commit's
parent, so a push that lands meanwhile is merged by the PR and not reverted.

The commit message and PR body include a `Cause: <40-hex sha>` line. Its form is fixed because
the policy check parses it ([05](./05-policy.md)).

## The PII scan

`bridge/src/bridge/pii.py` is deliberately simple. It flags email addresses, well-known token
formats (GitHub, `sk-`, AWS access key IDs, JWTs, Slack), private-key headers, and IPv4 and IPv6
addresses other than loopback. It does not flag bare hex, because commit SHAs and pod hashes are
everywhere in an analysis. Text is normalized first (Unicode format characters dropped, NFKC
folded) so zero-width characters and fullwidth forms cannot hide an address.

The scan covers everything that carries model text and leaves the bridge: the comment or PR body,
the PR title and commit message, and the analysis event's data. One hit blocks all of it. The
bridge instead posts a fixed notice listing only the kinds found ("personal data or a secret
(email, token)"), counts `aiops_pii_leaks_caught_total{kind}`, and a human takes over.

## Comment and PR templates

In `bridge/src/bridge/templates/`:

| Template | Used for |
|----------|----------|
| `rca_comment.md.j2` | The `suggest` comment: root cause, up to two evidence bullets plus a Timeline bullet, the `Cause:` line, and "what a human should do" |
| `fix_pr_body.md.j2` | The fix PR: root cause, blast radius (what changes and what is left alone), evidence for the reviewer, a collapsed table of the last five synced revisions, and a footer stating the level |
| `refusal_comment.md.j2` | A refusal, with each reason and detail |
| `pii_blocked_comment.md.j2` | The PII notice |
| `pr_sections.yaml` | Every heading and fixed sentence for the PR body and refusals, in one file |

Model text is cut to its first sentence and to a length cap (200 characters for the root cause,
160 for each evidence item), so a body reads on a projector, and the full text stays in the
analysis event. Before it is posted, `plain()` drops format characters, collapses whitespace,
escapes link, image and code syntax, and breaks `@mentions`, `#123` and `GH-12` issue references
and bare URLs, so model text cannot notify anyone, link to another issue or embed a tracking
image.

## Events

The bridge posts its own CDEvents to cdevents-sim: `dev.cdeventsx.holmesgpt-rca.completed`,
`dev.cdeventsx.agent-action`, `change.created` for a fix PR and `change.merged` for a merge. All
carry `BRIDGE_EVENT_SOURCE` as their source, so the sim keeps them off `/timeline` and
HolmesGPT never reads them. With no source configured, no event is sent.

## HolmesGPT

Installed by `make holmes-install` from the pinned chart (`platform/holmes/values.yaml`).

- **Read-only RBAC.** The chart's ClusterRole holds only `get`, `list` and `watch`, with no
  `secrets`, no wildcard and no `exec`, `attach`, `portforward`, `proxy` or `token` subresources.
  `make holmes-rbac-check` renders the chart offline and fails on any other rule; `make
  holmes-install` runs it first and then checks the live role with `kubectl auth can-i`. Of the
  chart's optional CRD grants, only Argo's (Applications, Rollouts, AnalysisRuns) is on.
- **Toolsets.** On: `kubernetes/core`, `argocd/core`, `prometheus/metrics`, and a custom HTTP
  toolset `cdevents-timeline`. Off: `bash`, `internet`, `robusta`, `skills`, `connectivity_check`.
- **The timeline toolset** allows only `GET` on the exact paths `/timeline` and `/incidents` on
  cdevents-sim. A glob such as `/timeline*` could be bypassed with `..`, so there is none.
  `make holmes-rbac-check` also runs a test of the allow-list in the pinned image.
- **Argo CD access** is the `holmesgpt` account with `role:readonly`.
- **Scope.** The instructions confine it to the `demo` namespace; `aiops` runs the tooling around
  the investigation, including earlier outputs, and is out of scope.
- **No GitHub credential.** The pod's environment holds the LiteLLM virtual key, the read-only
  Argo CD token and the API key the bridge presents.

## LiteLLM and the budget

HolmesGPT reaches a model only through LiteLLM (`platform/litellm/`), with a virtual key per
caller (`holmes` and `judge`, made by `make litellm-keys`). Aliases: `rca` and `judge`.

- `LLM_BUDGET_USD` sets `max_budget` for the proxy (30-day window). The value comes from `.env`
  at install time and is not committed. Set a spend limit at the provider as well: the proxy's
  budget is a guard, the provider's limit is the real cap.
- Every call is kept in LiteLLM's spend log, prompts included
  (`store_prompts_in_spend_logs`).
- `make llm-spend` shows live and cumulative spend against the budget. The cluster's Postgres
  dies with the cluster, so `make rm-kind` first runs `make llm-spend-export` to keep the totals
  in `.dryruns/llm-spend/`.
- HolmesGPT's temperature is 1 because it sends a near-zero temperature by default and LiteLLM
  rejects that for Claude.

## Test hooks

Two settings can be moved off their defaults by an optional Secret `bridge-env`, for the
failure-path tests: a confidence threshold above 1 (forces a refusal) and a very short HolmesGPT
timeout (forces a handoff). The Deployment pins everything else, so the Secret cannot reach other
settings. `/status` reports `test_hooks_active`. `make bridge-hooks-check` fails while the Secret
exists, `make bridge-hooks-clear` deletes it and restarts the bridge, and `make preflight` checks
it too.

## Dry forge

`DRY_FORGE=true` in the bridge Deployment turns every GitHub write into a `▸ dry: would ...` line
and keeps reads real. The committed Deployment has it off.
