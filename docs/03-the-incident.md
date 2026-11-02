# 03. The Incident

## Overview

The demo has one incident, on purpose, so that the only thing that changes between rungs is how
much the agent is trusted. It is a small mistake that looks fine in review and passes every
check except the one that runs the code.

## The pieces

| Piece | What it does |
|-------|--------------|
| `apps/checkout/config/checkout-config.yaml` | A ConfigMap with `UPSTREAM_TIMEOUT_MS: "2000"` and `PRICING_URL` |
| `apps/checkout/deploy/rollout.yaml` | A Rollout with 4 replicas. It loads the ConfigMap with `envFrom`. The pod template has the annotation `example.dev/config-version: "8"` |
| `apps/checkout/app/main.py` | Reads `UPSTREAM_TIMEOUT_MS` **once, at startup**, calls pricing with that timeout, returns 502 on a timeout, and exports the value it read as the gauge `checkout_config_upstream_timeout_ms` |
| `apps/pricing/app/main.py` | Answers `/price` after 300 to 450 ms (mean 350 ms) |
| `apps/checkout/deploy/analysistemplate.yaml` | The canary gate: the success rate of the canary's pods must be at least the SLO (99, from a pod label). Measured every 10 s from a Prometheus query |

With a timeout of 2000 ms every request succeeds. With 200 ms, nearly every request times out,
because pricing alone takes about 350 ms.

## The timeline of the incident

1. **The change.** A commit (PR-242, "tune upstream timeout for faster failover") changes
   `UPSTREAM_TIMEOUT_MS` from 2000 to 200. It does **not** change `example.dev/config-version` on
   the pod template. Nothing in the diff looks wrong: it is one number in a ConfigMap.
2. **Argo CD syncs it.** The ConfigMap now says 200. The Rollout's pod template is unchanged, so
   Rollouts starts nothing. The running pods keep serving with the 2000 they read at startup.
   Everything is green.
3. **A routine deploy.** Someone bumps the image tag (`make bump`). That changes the pod
   template, so Rollouts starts a canary at 25%. The canary pods start now, read the ConfigMap,
   and get 200.
4. **The canary fails.** Their success rate drops far below 99. The AnalysisRun fails within
   about 30 s, before the steps (about 40 s of pauses) could promote. The Rollout aborts and
   Argo CD reports the application Degraded.
5. **Notifications fire.** The bridge gets its webhook and the timeline gets `incident.detected`.

The commit that caused the incident (step 1) is not the commit that deployed when it failed
(step 3). That gap is what the agent has to bridge, and why the analysis cites a cause commit
that is different from the synced revision. The bridge's guardrails require the cited cause to
be a commit in the Argo history or an ancestor of the synced revision that changed the key.

## Why stable pods recreated after the abort also read the bad value

It is tempting to read this as "the new version is bad, the old version is fine". That is not
what the cluster does.

The ConfigMap is shared, not versioned with the pods, and `checkout` reads it only at start.
During the canary steps, Argo Rollouts (replica-based canary) scales the stable ReplicaSet down
to make room, and on abort scales it back up. The pods it starts then are new processes: they read
the ConfigMap as it is now, which says 200. So after the abort, stable pods started after the
config change are also bad, and the success rate stays low even though the Rollout has "gone
back".

The rule that holds, which the tests check by start time: every pod that started before the config
change was synced reads 2000, and every pod that started after it reads 200, canary or stable.
The agent is told to group pods this way, by start time against the sync time, and not by
canary versus stable. The prompt step says why.

This is also why the app exports the value it read as a metric. The evidence (per-pod values over
the incident window) is still in Prometheus after the canary pods are gone.

## Why a naive revert shows Healthy while the SLO still fails

`make naive-revert` reverts the image bump, which is what many people would try first.

- The revert puts the pod template back to what the stable ReplicaSet already runs. Rollouts has
  nothing to roll, the Rollout is Healthy, and so is the Argo CD application. Health here says
  the desired and running specs match. It does not say requests succeed.
- The ConfigMap still says 200. Every pod started since the config change still reads 200 and
  still returns 502s, so the success-rate panel on the dashboard keeps showing the SLO missed
  while Argo CD shows green.
- It is worse than wrong. The reverted image is older than `CHECKOUT_CVE_TAG` (v1.4.2, the first
  tag with the security fix in the example `CHANGELOG.md`), so the revert also removes the fix.
  The script refuses unless the revert would land below that tag.
- The next unrelated deploy starts new pods, which read 200 and abort the canary again.
  `make naive-revert` shows that second failure too (`NAIVE_STOP_AT_GREEN=1` stops after the first
  half).

The point for the talk: a green status was never the question. The SLO was. An agent that watches
only deployment health would call this fixed.

## The real fix

`make fix` restores the timeout to 2000 and bumps `config-version` in the same commit. Two values
change. The pod template changes, so the whole fleet rolls and every pod reads the restored value.

The agent's fix PR is the same two lines. The bridge builds it from the model's `proposed_patch`
(file, key, from, to) with a line-level edit that keeps comments and formatting, then re-parses
both files to prove only the intended values changed. See [04](./04-bridge-and-holmes.md).

The durable remedy is outside the demo: hash the config into the pod template (for example with
Kustomize's `configMapGenerator`), so a config change rolls the pods without a hand-bumped
annotation.

## What the agent has to work out

The change event on the timeline carries only what a forge would send: SHA, title, changed files,
author, time and a change reference. It does not say which key changed, from what, to what, or
that config-version was left alone. The agent must find:

- the timeout values from the ConfigMap and the per-pod gauge,
- which commit introduced 200, from the timeline and Git history,
- that the annotation did not change between the stable and canary ReplicaSets,
- whose SLO was at risk, from the owner and SLO labels on the Rollout.

A correct answer cites the change reference from the timeline, which exists only in the event and
never in Git or the cluster. Citing it is how a run shows the timeline was read.

## Resetting

| Goal | Command |
|------|---------|
| Make the incident happen again | `make rearm` (refuses if the branch is already armed) |
| Restore the working state | `make disarm` (add `IMAGE=v1.4.1` to pin the tag; `GIT_ONLY=1` skips the wait) |
| Heal it the human way | `make fix` |
| Show the wrong way | `make naive-revert` |

`make seed-history` is the first-run setup: it disarms, then commits the PR-242 change and one
unrelated docs change, so the history has a believable cause among other commits.
