# Recorded HolmesGPT 0.45.0 responses

Raw `POST /api/chat` responses from HolmesGPT 0.45.0 (`robustadev/holmes:0.45.0`), recorded in
docker with the toolset set used by the demo (one http toolset `cdevents-timeline`, everything
else disabled). Keys, IPs and request IDs are scrubbed.

## Read this first: what is real

The model never answered. The Anthropic account behind the build key returned
`Your credit balance is too low to access the Anthropic API` on every call, through LiteLLM
v1.106.4. So the model turns in these files come from a scripted OpenAI-compatible stub, not
Claude. What is real: the HolmesGPT response envelope, how tool calls are reported, the
http-toolset allow-list behaviour, the request HolmesGPT sends to the LLM endpoint, and
`X-API-Key` auth. What is not yet recorded: Claude's strict `response_format` output through
LiteLLM, which host form Claude chooses, and real latency. Re-record `rca_ok.json` against
Claude once the account has credit.

## Files

| File | What it is |
|---|---|
| `chat_request_bridge_to_holmes.json` | The request body the bridge sends (strict RCA schema inside `response_format`) |
| `chat_request_holmes_to_llm.json` | What HolmesGPT sends on to the LLM endpoint (system prompt truncated) |
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
- `metadata.usage`/`costs` come from the stub and are not meaningful.

## Contract findings

1. Auth: `X-API-Key` works (401 without it). `Authorization: Bearer <key>` was also accepted.
2. HolmesGPT sends `temperature: 0` (from the `modelList` entry), `tool_choice: "auto"`,
   `max_tokens: 64000`, `response_format` = the strict json_schema unchanged, and
   `strict: true` on **every** tool, including its built-in `TodoWrite`, even with
   `behavior_controls.todowrite_*` false.
3. **`temperature: 0` is rejected for `claude-sonnet-5-5`** by LiteLLM
   (`UnsupportedParamsError: ... Only temperature=1 is supported`). Either omit `temperature`
   from the Holmes `modelList.rca` entry or set `litellm_settings.drop_params: true` (with it,
   the request reaches Anthropic).
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
