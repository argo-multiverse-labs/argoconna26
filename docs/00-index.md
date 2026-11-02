# Documentation Index

**Project:** ArgoCon NA 2026, "Observability Is a Platform Problem Now: Closing the AIOps Loop
with ArgoCD and GitOps"

These pages describe how the demo is built and why. They are written from the code on the
`build/demo` branch. Where a part is still being built, the page says so.

Start with the [README](../README.md) for what the demo shows and how to run it.

## Documents

| Doc | Title | Scope |
|-----|-------|-------|
| [01](./01-architecture.md) | Architecture | Components, namespaces, data flow, ports |
| [02](./02-trust-ladder.md) | The Trust Ladder | `aiops/autonomy.yaml`, the three levels, promotion and demotion, what GitHub enforces vs what the bridge enforces |
| [03](./03-the-incident.md) | The Incident | The timeout change, why it slips past a rollout, why a naive revert looks green |
| [04](./04-bridge-and-holmes.md) | Bridge and HolmesGPT | Webhook, investigation, guardrails, PII scan, templates, read-only RBAC, LLM budget |
| [05](./05-policy.md) | Policy | Golden-path labels, Git facts, the auto-fix rules, the `policy-check` workflow and its trust boundary |
| [06](./06-operations.md) | Operations | Make targets, operator clone, resets, isolated kubeconfig, tests |
| [github-setup](./github-setup.md) | GitHub Setup | The GitHub App, rulesets and repository settings to reproduce on a fork |

## Reading Paths

| If you want to | Read |
|----------------|------|
| Run the demo | README, then 06 |
| Understand the safety model | 02, then 04 and 05, then github-setup |
| Understand the incident | 03, then 01 |
| Fork it | README (Quick Start), github-setup, 06 |

## Key Design Decisions

| Decision | Choice | Why | Doc |
|----------|--------|-----|-----|
| What the agent may do | A file in Git (`aiops/autonomy.yaml`), read at each incident | Raising trust is a reviewed PR; a missing or broken file means `suggest` | 02 |
| Who writes | Only the bridge, only through a GitHub App, only as PRs and comments | The model never holds a credential; rulesets bound the App | 02, 04 |
| HolmesGPT | Read-only, no GitHub credential | The analysis step cannot act, whatever the model says | 04 |
| The model's output | Checked by the bridge before anything is posted | Normalize, then refuse anything that does not check out | 04 |
| The fix | Built by the bridge as a two-line edit | The model names the change; it does not write the diff | 04 |
| Auto-merge | Allowed by a policy over Git facts, enforced by a required check | A deny-by-default rule set that a PR cannot loosen | 05 |
| Timeline | A simulator in place of a collector | Keeps the demo to one laptop; the data shape is real CDEvents | 01 |
| Cluster access | An isolated kubeconfig and a cluster lock | No script touches another context | 06 |
