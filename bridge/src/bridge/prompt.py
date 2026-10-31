"""The runbook prompt: one scenario, the places to look, and the shape of the answer.

It names where to look but not what is wrong: the values, the key's history and
whether config-version was bumped are for the agent to find.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from .models import ArgoDegradedHook

TIMELINE_URL = "http://cdevents-sim.aiops.svc:8080/timeline"
CONFIG_VERSION_ANNOTATION = "example.dev/config-version"
LOOKBACK = timedelta(hours=72)
LIVE_BEFORE = timedelta(minutes=10)
LIVE_AFTER = timedelta(minutes=1)


def live_window(received_at: datetime) -> tuple[datetime, datetime]:
    """The incident window for a live webhook: 10 minutes before receipt to 1 minute after."""
    return received_at - LIVE_BEFORE, received_at + LIVE_AFTER


def _rfc3339(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("incident window times must be timezone-aware")
    return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_prompt(
    hook: ArgoDegradedHook,
    incident_window: tuple[datetime, datetime],
    owner_labels_hint: bool = True,
    *,
    timeline_url: str = TIMELINE_URL,
    config_version_annotation: str = CONFIG_VERSION_ANNOTATION,
) -> str:
    start, end = (_rfc3339(t) for t in incident_window)
    lookback = _rfc3339(incident_window[1] - LOOKBACK)
    app, ns = hook.app, hook.namespace
    history = "\n".join(
        f"  - id {h.id}: {h.revision} deployed {_rfc3339(h.deployedAt)}" for h in hook.history[-5:]
    ) or "  - (none sent)"

    steps = [
        f"Read the Argo Rollout `{app}` in namespace `{ns}`: its status message, its canary "
        "steps, the RolloutAborted event and the failed AnalysisRun measurements.",
        f"In Prometheus, compare `{app}_config_upstream_timeout_ms` by pod over the incident "
        f"window (from {start} to {end}): canary pods against stable pods. Also look at "
        f"`{app}_requests_total` by code and pod over the same window.",
        f"Read the `{app}-config` ConfigMap in `{ns}` and compare its values with what the "
        "stable and canary pods reported.",
        f"Query the delivery timeline with the `cdevents-timeline` toolset: "
        f"GET {timeline_url}?app={app}&since={lookback} (the 72 hours before the window ends). "
        "Find the change event for the commit that introduced the config value the canary "
        "pods ran with. Note its change reference (`change_ref` in customData), its commit "
        "SHA and how long before the abort it landed.",
        f"Check whether that change also bumped the `{config_version_annotation}` annotation "
        "on the pod template: compare the annotation on the stable and canary ReplicaSets, and "
        "the application's manifests at the synced revision in Argo CD. The change event does "
        "not say.",
    ]
    if owner_labels_hint:
        steps.append(
            f"Read the owner and SLO labels on the Rollout (`example.dev/owner`, "
            "`slo.example.dev/success-rate`) and say whose SLO was at risk."
        )
    runbook = "\n".join(f"{i}. {s}" for i, s in enumerate(steps, 1))

    return f"""\
You are investigating one incident. You can read the cluster, Argo CD, Prometheus and the \
delivery timeline. You cannot change anything.

Incident
- Argo CD application `{app}` (workloads in namespace `{ns}`) is {hook.health}.
- Synced revision: {hook.sync_revision}
- Incident window: {start} to {end} (UTC). Anchor every Prometheus query to this window.
- Recent Argo CD sync history:
{history}

Runbook. Work through these steps in order.
{runbook}

Answer with the RCA object:
- root_cause: one sentence.
- cause_commit_sha: the full 40-character SHA of the commit that introduced the bad config \
value. It is not necessarily the synced revision. Never shorten it.
- evidence: one to three short items, each starting with its source (Prometheus, ConfigMap, \
Rollout, AnalysisRun, Timeline, Argo CD).
- delivery_context: one sentence from the timeline: the change reference, the short SHA and how \
long before the abort it landed.
- confidence: 0 to 1. Lower it when the evidence is thin; never guess a SHA.
- proposed_patch: the repo-relative path of the config file in Git \
(for example apps/{app}/config/{app}-config.yaml), the key, `from` (its current value) and \
`to` (the value to restore). Only the config value: the config-version bump is added for you.

Rules
- Never include IP addresses, email addresses, tokens, passwords or any Secret value in any \
field.
- Do not read Kubernetes Secrets.
"""
