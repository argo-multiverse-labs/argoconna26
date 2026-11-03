# cdevents-sim

A small stand-in for cdviz-collector + Postgres. It accepts CDEvents, keeps them in a JSONL file, and serves a read-only query API. The CDEvents schemas are the v0.5.1 ones, vendored in `schemas/v0.5.1/`.

Run the tests with `uv run pytest`.

## Configuration

| Variable | Meaning |
|---|---|
| `BRIDGE_EVENT_SOURCE` | **Required.** The bridge's CloudEvents `source` (`demo.env`). `/timeline` drops every event from it, plus every `dev.cdeventsx.*` event, so HolmesGPT never reads the agent's own outputs. The sim refuses to start without it. |
| `CDEVENTS_STORE` | JSONL store path, default `/data/events.jsonl`. The image creates `/data` for its runtime user; the Deployment mounts a PVC there. A partial last line (a pod killed mid-write) is dropped on the next start. |
| `SEED_FIXTURE` | Fixture loaded at startup, timestamps relative to now. |

An operator change event names no app. The sim takes the app from `customData.changed_files` when every path is under the same `apps/<app>/`.

## POST /seed

Loads the fixture again with timestamps relative to now (idempotent on event id). Query: `reset=true` first drops the fixture's events and every live event older than `keep_live_hours` (default `0`: all of them), so each rehearsal starts from the same timeline. Optional body `{"checkout_revisions": [sha, ...]}` (oldest first) gives the fixture's recent checkout deployments real commits to point at; without it those events are skipped, so nothing inside the 72 h lookback names a revision that does not exist. Answers `{"added": n, "dropped": n}`.
