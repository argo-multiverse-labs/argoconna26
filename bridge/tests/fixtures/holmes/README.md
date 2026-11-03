# Recorded HolmesGPT 0.45.0 responses

Raw `POST /api/chat` responses from HolmesGPT 0.45.0 (`robustadev/holmes:0.45.0`), recorded in
docker with the toolset set used by the demo (one http toolset `cdevents-timeline`, everything
else disabled). Keys, IPs and request IDs are scrubbed.

## Read this first: what is real

`rca_ok.json` and `rca_toolcall_timeline.json` were re-recorded on 2026-10-31 against real
Claude (`claude-sonnet-5-5`, through LiteLLM v1.106.4): the model turns, the strict `response_format`
output and the tool calls are real model output. Each is one call with one successful
`cdevents_timeline_request`; the stub behind the toolset serves two fixed timeline rows, so the
facts the model reads are scripted, its reasoning is not. `rca_toolcall_refused_events.json` and the two
`chat_request_*` files are unchanged and still come from the earlier run with a scripted model
(the refused-path behaviour is the toolset's, not the model's). Keys, IPs and request IDs are
scrubbed.

**Edited after recording:** the stub served the merge row as `dev.cdevents.change.merged.0.4.0`,
a type CDEvents v0.5.1 does not define (it defines `change.merged.0.3.0`). That type string was
changed to `0.3.0` in place, in the tool result and in the conversation history, so nothing
copied from these files carries a type the vendored schema rejects
(`test_fixture_event_types.py` checks this). Nothing else in the recordings was changed.

### What these files do not prove (use them as parse and contract fixtures only)

They prove the envelope and the request contract, not an RCA the bridge would accept, so they
are never the happy path in a pipeline test (Task 3.9):

- Both analyses report `confidence: 0.6`, under the bridge's `confidence_threshold` (0.7), and
  `proposed_patch.file` is free text, so the guardrails would refuse them (low confidence or a
  disallowed file).
- The stub's merge row is not the event shape the demo uses (Δ28): its summary names the key,
  both values and "config-version not bumped", which gives the answer away, and its revision
  `bbbb…` (2026-10-31T10:12Z) is a fake SHA inside the 72 h lookback, which O6 rules out. So they
  don't show that the model finds the cause from Δ28-shaped events.
- Re-record in Task 3.12 against a Δ28-shaped timeline whose checkout events point at real
  seeded commits, and check that the confidence clears 0.7.

Measured on the real run: strict mode works through LiteLLM to Claude; the model used the
`cdevents-sim.aiops.svc:8080` host form; one call takes about 9 to 10 s end to end. In one of
three runs Claude's first two timeline calls failed on bad tool parameters (`max_depth`, then a
type error inside the toolset) before the third succeeded, so the client must not assume exactly
one tool call.

## Files

| File | What it is |
|---|---|
| `chat_request_bridge_to_holmes.json` | The request body the bridge sends (strict RCA schema inside `response_format`) |
| `chat_request_holmes_to_llm.json` | What HolmesGPT sent on to the LLM endpoint in the scripted run (system prompt truncated). Its `temperature: 0` is the pre-fix value Claude rejects; it is not the request contract (see finding 3) |
| `rca_ok.json` | Full response envelope |
| `rca_toolcall_timeline.json` | Same, with a successful `cdevents_timeline_request` call |
| `rca_toolcall_refused_events.json` | A call to `/events` refused by the path allow-list |

## Envelope (what the client parses)

- Top-level keys: `analysis`, `conversation_history`, `tool_calls`, `follow_up_actions`,
  `pending_approvals`, `metadata`.
- `analysis` is a **string** holding the JSON; `json.loads` it.
- `tool_calls[]`: `tool_call_id`, `tool_name` (here `cdevents_timeline_request`),
  `toolset_name` (`cdevents-timeline`), `description`, and `result` with `status`
  (`success` or `error`), `error`, `data` (a JSON **string**: `{"status_code":..,"body":..}`),
  `url`, `params`, `elapsed_seconds`.
- Use `tool_calls[].toolset_name`/`tool_name`/`url` for the stage log. The `_fixture` key was
  added to each file by hand and is not part of the API.
- `metadata.usage` is real token usage in the two re-recorded files (the other file still has stub numbers).

## Contract findings

1. Auth: `X-API-Key` works (401 without it). `Authorization: Bearer <key>` was also accepted.
2. HolmesGPT sends the `modelList` entry's temperature (`0` in the scripted run's entry, which
   Claude rejects; see 3), `tool_choice: "auto"`,
   `max_tokens: 64000`, `response_format` = the strict json_schema unchanged, and
   `strict: true` on **every** tool, including its built-in `TodoWrite`, even with
   `behavior_controls.todowrite_*` false.
3. **Set `temperature: 1` in the Holmes `modelList.rca` entry** (measured 2026-10-31: it works,
   and it is the temperature Claude applies). `claude-sonnet-5-5` accepts only temperature 1:
   `temperature: 0` is rejected by LiteLLM (`UnsupportedParamsError: ... Only temperature=1 is
   supported`), and omitting `temperature` is not enough either, because HolmesGPT then sends
   `temperature: 1e-08`, which is rejected the same way. `litellm_settings.drop_params: true` let
   the scripted-run request reach Anthropic, but it was not re-measured against Claude and it
   hides what the provider applied, so it is not the recommendation.
4. **Path globs are bypassable.** With `paths: ['/timeline*']`, a tool call to
   `/timeline-x/../events` passed the allow-list and the stub received `GET /events`. Use exact
   paths (`/timeline`, `/incidents`). Exact paths allow query strings, refuse `/events`,
   `/timeline/../events` and `/timeline-x/../events`, and refuse other hosts.
5. Both host forms (`cdevents-sim.aiops.svc:8080` and `...svc.cluster.local:8080`) pass when
   listed in `hosts`.

Toolset config used:

```yaml
cdevents-timeline:
  type: http
  enabled: true
  config:
    endpoints:
      - hosts: ["cdevents-sim.aiops.svc:8080", "cdevents-sim.aiops.svc.cluster.local:8080"]
        paths: ["/timeline", "/incidents"]
        methods: ["GET"]
    timeout_seconds: 30
    block_internal_ips: false
```

The strict RCA schema used is the `response_format.json_schema.schema` in
`chat_request_bridge_to_holmes.json`.
