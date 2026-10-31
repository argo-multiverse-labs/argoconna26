# cdevents-sim

A small stand-in for cdviz-collector + Postgres. It accepts CDEvents, keeps them in a JSONL file, and serves a read-only query API. The CDEvents schemas are the v0.5.1 ones, vendored in `schemas/v0.5.1/`.

Run the tests with `uv run pytest`.
