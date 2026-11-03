# bridge

The bridge receives Argo CD Notifications webhooks for a Degraded application,
reads the agent's autonomy level from `aiops/autonomy.yaml` in Git, asks a
read-only HolmesGPT for a structured root-cause analysis, applies guardrails and
a PII scan, and then acts only through Git: a comment, a pull request, or a pull
request with auto-merge.

It holds the only Git-write credential in the cluster (a GitHub App installation
token). HolmesGPT has no write path.

```bash
uv sync
uv run pytest -q
```

Tests make no network calls: GitHub and HolmesGPT are stubbed with `respx`, and
test RSA keys are generated at test time.
