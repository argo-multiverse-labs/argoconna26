## Raise the agent from `${FROM_LEVEL}` to `${TO_LEVEL}`

This PR changes one file, `aiops/autonomy.yaml`. Once it is merged, the bridge reads the new level on the next incident. Nothing else changes.

| Level | What the agent may do |
|---|---|
| `suggest` | Post its root-cause analysis as a comment. |
| `propose` | Open a fix PR. A person merges it. |
| `act` | Merge its own fix when the policy check passes. A person reviews it afterwards. |

## What we checked

- **Dry runs:** ${VERDICT}${DRY_RUN_DETAIL}
- **Time at `${FROM_LEVEL}`:** ${TIME_AT_LEVEL}. The wait is compressed for the demo; in practice we would want at least ${WEEKS} weeks.
- **Who approves:** ${APPROVER}. The person who opened this PR cannot approve it.

## For the reviewer

These criteria are a first draft. The promotion board owns them and can rewrite them.

Approve only if this evidence is enough for you to trust the agent with the next level. If it is not, close the PR and say why.

A repo admin can merge without a review. The record in `aiops/autonomy.yaml` then says `admin-bypass`, so it never claims an approval that did not happen.

Lowering the level later is one commit: `make demote`.
