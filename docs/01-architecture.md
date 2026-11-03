# 01. Architecture

## Overview

A kind cluster runs a small checkout service with a canary rollout, the platform that observes
and deploys it, and an agent that reacts when a deploy fails. Argo CD tracks one Git branch
(`TRACKED_BRANCH`, `main`; it was `build/demo` while building). Everything the agent changes goes through that
branch as a pull request.

## Components

| Component | Namespace | What it does | Source |
|-----------|-----------|--------------|--------|
| Argo CD (with Notifications) | `argocd` | Syncs every Application from the tracked branch. Notifications send CDEvents to cdevents-sim and the Degraded webhook to the bridge. Reconciles every 20 s so the demo is quick. | `platform/argocd/` |
| Argo Rollouts | `argo-rollouts` | Runs the `checkout` canary and its AnalysisRun. | `platform/rollouts/` |
| kube-prometheus-stack | `monitoring` | Prometheus and Grafana. The "Trust ladder" dashboard is provisioned from the `dashboards` Application. | `platform/kps/`, `platform/grafana/` |
| checkout | `demo` | The service under test: a Rollout with 4 replicas, a ConfigMap, a ServiceMonitor and the success-rate AnalysisTemplate. | `apps/checkout/` |
| pricing | `demo` | A deliberately slow dependency (about 350 ms per request). | `apps/pricing/` |
| loadgen | `demo` | Steady traffic against checkout (20 requests per second by default). | `apps/loadgen/` |
| cdevents-sim | `aiops` | Accepts CDEvents, stores them in a file on a PVC, serves a read-only query API, and writes Grafana annotations. | `cdevents-sim/` |
| bridge | `aiops` | Receives the webhook, runs the pipeline, writes to GitHub. The only component with a Git-write credential. | `bridge/` |
| HolmesGPT | `aiops` | Investigates and returns a structured analysis. Read-only. | `platform/holmes/` |
| LiteLLM and Postgres | `aiops` | The only route from HolmesGPT to a model. Enforces a budget and keeps a call log. | `platform/litellm/` |

The Applications are defined in `gitops/apps/`, owned by one app-of-apps root
(`gitops/root.yaml`) that `make gitops-bootstrap` applies. Platform pieces (Argo CD, Rollouts,
kube-prometheus-stack, LiteLLM, HolmesGPT) are installed by Helm from make targets, not by
Argo CD. Argo CD manages `checkout`, `pricing`, `loadgen`, `bridge`, `cdevents-sim` and
`dashboards`.

## Data flow

```
 1  git push (operator or merged PR)  -->  GitHub main
 2  Argo CD syncs checkout            -->  Rollout starts a canary (25%, 20 s, 50%, 20 s)
 3  AnalysisRun queries Prometheus    -->  success rate of canary pods vs the SLO label
 4  success rate under SLO            -->  Rollout aborted, Application Degraded
 5  Notifications                     -->  CDEvents (incident.detected) to cdevents-sim
                                       -->  webhook to the bridge (bearer token)
 6  bridge reads aiops/autonomy.yaml from GitHub at the tracked branch
 7  bridge --> HolmesGPT POST /api/chat with a runbook prompt and a strict JSON schema
 8  HolmesGPT reads: Rollout and pods (kubectl), Argo CD, Prometheus, GET /timeline
 9  HolmesGPT --> LiteLLM --> model;  structured analysis returns to the bridge
10  bridge: guardrails -> render -> PII scan -> comment | PR | PR + auto-merge
11  merge --> Argo CD syncs --> new pods --> Healthy --> incident.resolved on the timeline
```

Notes on the steps:

- **Step 2 to 4.** The AnalysisRun uses a 10 s interval, one allowed failure, and treats "no
  data" as inconclusive, not as success. See [03](./03-the-incident.md).
- **Step 5.** The webhook body carries the app name, namespace, the revision, the synced
  revision, the health, the Argo history, the repo URL and the target revision. Argo
  Notifications send it once per health transition (`oncePer:
  app.status.health.lastTransitionTime`), so a fix that syncs while the aborted rollout still
  reports Degraded does not start a second incident. A malformed body gets a 4xx,
  never a 5xx, so Notifications do not retry in a loop.
- **Step 6.** The level is read per incident, so a promotion takes effect on the next one. See
  [02](./02-trust-ladder.md).
- **Step 8.** HolmesGPT's timeline toolset is limited to `GET /timeline` and `GET /incidents` on
  cdevents-sim, as exact paths. `/events` holds the agent's own earlier output and is left out.
  The sim also drops the agent's events and all `dev.cdeventsx.*` events from `/timeline`. The
  agent never reads its own earlier analyses or actions.
- **Step 10.** Every agent action also produces an event on the timeline (analysis completed,
  change created, change merged, action taken), so the dashboard shows it.

## CDEvents

Events use CDEvents v0.5.1. The schemas are vendored in `cdevents-sim/schemas/v0.5.1/` and the sim
validates what it accepts. Sources of events:

| Source | Events |
|--------|--------|
| Argo CD Notifications (`platform/argocd/notifications-cdevents.yaml`) | `service.deployed`, `incident.detected` (on Degraded and on a failed sync) and `incident.resolved` |
| The operator scripts (`scripts/common.sh`, `emit_change_event`) | `change.merged` for each commit they push, source `/argoconna26/operator` |
| The bridge (`bridge/src/bridge/events.py`) | Analysis completed and agent action (both `dev.cdeventsx.*` custom types), `change.created`, `change.merged`, source `BRIDGE_EVENT_SOURCE` |
| A seed fixture (`cdevents-sim/fixtures/seed-history.json`) | A few days of earlier deployments, so the timeline has history; loaded with `POST /seed` |

cdevents-sim endpoints: `POST /events`, `POST /seed`, `GET /events`, `GET /timeline`,
`GET /incidents`, `GET /annotations`, `GET /healthz`, `GET /metrics`.

## Ports and URLs

From `demo.env`. The host side binds `127.0.0.1` only, and each host port equals its NodePort.

| Service | Host port | In-cluster URL |
|---------|-----------|----------------|
| Argo CD | 30080 | `argocd-server.argocd.svc` |
| Grafana | 30030 | in `monitoring` |
| Prometheus | 30090 | `http://kps-prometheus.monitoring.svc:9090` |
| Bridge | 30081 | `http://bridge.aiops.svc:8080` |
| cdevents-sim | 30082 | `http://cdevents-sim.aiops.svc:8080` |
| LiteLLM | 30400 | `http://litellm.aiops.svc:4000/v1` |
| HolmesGPT | none | `http://holmes-holmes.aiops.svc` |

## Observability of the agent

The bridge exports Prometheus metrics at `/metrics`. The dashboard panels:

| Panel | Shows |
|-------|-------|
| Checkout success rate against the SLO | The incident, as users would see it |
| Delivery and agent events | A table of the sim's `/annotations` for the last 72 h: deploys, changes, incidents, agent actions |
| Steps a human must take at this autonomy level | `aiops_human_touchpoints{level}`, taken from `touchpoints` in `autonomy.yaml` |
| Trust metrics | Dry-run accuracy (or pending), fix PRs merged and rejected, guardrail refusals, PII hits caught, and total agent actions |

The touchpoints panel is a defined count per level, not a measurement: at `act` the one step is a
review after the fact.

## Deployment notes

- Images are built locally (`make images`) and loaded into the kind nodes with
  `imagePullPolicy: Never`. `checkout` has several preloaded tags (`CHECKOUT_PRELOAD_TAGS`) so
  an image bump needs no build during the demo.
- Argo CD's account `holmesgpt` has the `role:readonly` role. Its token is minted through the
  Argo CD HTTP API during `make secrets-late`, so no CLI session that could expire is involved.
- The bridge Deployment sets `automountServiceAccountToken: false` and has no RoleBindings. It
  does not talk to the Kubernetes API.
- Secrets are created from `.env` by `scripts/secrets.sh` (`make secrets-base`,
  `make secrets-late`). No secret value is committed.

## Version pins

From [versions.env](../versions.env). Nothing else in the repo hardcodes these.

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
