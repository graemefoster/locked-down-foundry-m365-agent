# Local run + Playground baseline (activity-ui-pilot)

Reproduces today's turn experience locally. No secrets: values come from your gitignored
`hello_world_a365_agent/.env.local` (see `.env.example`) and your `az login`.

## Steps
1. Venv (the checked-in `.venv` may be stale): from `hello_world_a365_agent/`
   `uv venv --python 3.12 .venv-local && uv pip install --python .venv-local/bin/python -r requirements.txt`
2. Agent (from `agents/advanced-autopilot-agent/`). **Unset the proxy vars** that `.env.local` sets
   (`HTTPS_PROXY=localhost:8866` etc.) unless that tunnel is up, else `az` token fetch fails:
   ```
   set -a; . hello_world_a365_agent/.env.local; set +a
   unset HTTPS_PROXY HTTP_PROXY REQUESTS_CA_BUNDLE CA_CERTS SSL_CERT_FILE
   PORT=8090 LOCAL_NO_MCP=1 hello_world_a365_agent/.venv-local/bin/python local_run.py
   ```
   `LOCAL_NO_MCP=1` drops the 6 MCP servers (blocked locally, see below); omit it to reproduce the 400.
3. Playground (set `-c msteams` to match Teams channel behaviour; verified wave3, v0.2.28):
   `npx -y @microsoft/m365agentsplayground -p 56170 -e http://localhost:8090/api/messages -c msteams`
   then open http://localhost:56170. (Port 8088/56150 may be taken by other local agents.)
4. Timestamped capture: `.agent-runs/activity-ui-pilot/baseline/inbound_proxy.py` (inbound, :8091 -> :8090)
   and `.agent-runs/activity-ui-pilot/playground/drive.cjs` (UI driver, records outbound frames + screenshot).
   See `.agent-runs/activity-ui-pilot/baseline/README.md`.

## v7 library + `demo` command
Vendored `m365_activity_ui` refreshed from agentcraft 208baa130. Chat turns: ProgressTracker card updates in place, `TurnPresenter(feedback=True)`;
`FormDesk` (via `UiToolkit(on_form_submit)`) and `FeedbackDesk` registered in `chat_turn.register_approvals`. A model-drawn form's submission starts a
NEW USER TURN ("I submitted the form with these values: ..."), run inline on the invoke context.
Type `demo` (`/demo`, `show me a demo`) for a deterministic sample-data gallery, no model call (`demo_turn.py`); `demo charts|figures|table|people|form|approval|sources|progress`
for one section. Each card is its own message (no attachment cap hit); the demo approval never sends.
Playground quirk: a persisted previous_response_id makes the model skip tool calls on repeat prompts; clear `RESPONSE_STORE_DIR` between runs.

## Mock Mail/Calendar (`MOCK_M365=1`)
Replaces the MCP tools with local function tools (`list_messages`, `get_message`, `list_events`) over a
generated, seeded fixture (25 messages incl. 3 threads, 6 events today/tomorrow, one overlap). Run as step 2
with `MOCK_M365=1` instead of `LOCAL_NO_MCP=1`. Regenerate/inspect: from `agents/advanced-autopilot-agent/`
`python -m mock_m365.generate --out fixture.json` (deterministic; dates relative to today, override `--today`).
Default (unset) path is unchanged: `_build_mcp_tools`. Evidence: `.agent-runs/activity-ui-pilot/mock-data/`.

## Activity UI (`m365_activity_ui`, local editable install)
Chat turns (non-email) use AgentCraft `libraries/m365-activity-ui` via `hello_world_a365_agent/chat_turn.py`:
progress lines, streamed markdown, KPI strip card (computed from mock tool results), `[n]` citations, AI label,
feedback buttons, follow-up prompts. Email and notification paths keep HTML. If the library is not importable the
host falls back to the old ack + typing flow.
- Install into the existing venv (uv only), path = your AgentCraft checkout, branch `feature/m365-activity-ui`:
  `uv pip install --python hello_world_a365_agent/.venv-local/bin/python -e <agentcraft>/libraries/m365-activity-ui`
- **remote_build gap:** the library is not pushed, so it is NOT in `requirements.txt`/`pyproject.toml`; a remote
  build will not have it (chat then uses the legacy flow). Add a git URL pin once the branch is pushed.
- `RESPONSE_STORE_DIR=<dir>` overrides `~/.a365agent` (fresh conversation state for repeatable runs; Playground
  reuses one conversation id, so a stored previous_response_id makes the model skip tool calls).
- Evidence: `.agent-runs/activity-ui-pilot/after/` (`activity_log.txt`, `mid_turn.png`, `final.png`,
  `nonstream_slack.txt`, `nonstream_email.txt`).

## Follow-up buttons and approvals (wave3)
`chat_turn.register_approvals(app, run_prompt, inline)` wires `ApprovalDesk.register(app)` (no manual add_route) and the
`prompt` invoke (PromptDesk logic). Verified in Playground with `MOCK_M365=1`: click "Draft a reply to ..." -> "You asked: ..."
echo -> real answer + approval card; Approve resolves the card in place ("Approved by ..."), `MOCK SEND #1` logged.
- **Library finding 1:** `PromptDesk.register` uses an `async def` selector; hosting-core 1.7 calls `route.selector(ctx)`
  unawaited, so the route never matches (`RuntimeWarning: coroutine ... _selector was never awaited`, button does nothing).
  Host registers the same route with the sync `desk.matches`.
- **Library finding 2:** PromptDesk runs `run_prompt` after the invoke ack; the invoke turn's connector client is closed
  then: `send_activity` -> `AssertionError: assert self._connector is not None` (aiohttp). Evidence: `.agent-runs/activity-ui-pilot/wave3/try1/agent.log`.
- Fallbacks in `host_agent_server.py`: with CLIENT_ID+TENANT_ID+CLIENT_SECRET set (deployed) the turn runs on a proactive
  `continue_conversation` context (UNVERIFIED here: no credentials); locally (anonymous) `continue_conversation` fails with
  `TENANT_ID is not set in the configuration` (try2), so the turn is awaited inline in the invoke handler and the 200 is
  returned after the turn (~5 s; Teams' invoke timeout is short). Override with `PROMPT_RUN_MODE=inline|proactive`.

## Email locally (`email_harness/`)
"Send the agent an email" with no Outlook/tenant. Start your own agent as in step 2 with `MOCK_M365=1` (and a spare
`PORT`, `RESPONSE_STORE_DIR` for fresh state), then from `agents/advanced-autopilot-agent/`:
```
python3 email_harness/send_email.py --from Alex --subject "What does my day look like?" \
  --body "Hi, what does my day look like today?" --agent http://localhost:8095 --out <dir>
```
Stdlib only (screenshot via `shot.cjs`, needs playwright-core from `.agent-runs/activity-ui-pilot/playground/node_modules`).
- Posts an `agents:email` activity with an `emailNotification` entity (`id`, `conversationId`, `htmlBody`) to `/api/messages`;
  the SDK's `AgentNotificationActivity` parses it and `is_email_notification` is true. `serviceUrl` points at a throwaway
  local server that captures the agent's outbound `emailResponse` entity -> `reply.html`, `reply_600.png`, `summary.json`,
  `request.json`, `captured_outbound.json`.
- Recipient must NOT have `role: agenticUser` locally (the SDK would then demand an agentic token -> 500).
- `--mode plain` sends a Teams-style message through the same capture (negative check: not treated as email, goes to the chat turn).
- The library's email entity has no subject; the harness puts `Subject: ...` at the top of `htmlBody`. Real Outlook payload content is unverified.
- `--quote-from <earlier reply.html>` sends `--body` as a reply with quoted history (`<hr><blockquote>`), e.g. `--body "APPROVE AP-xxxxxx"`.
- Email replies (MOCK_M365=1 only) use `hello_world_a365_agent/email_turn.py` over `m365_activity_ui.email`: the model writes markdown prose; code adds
  figures (`compute_totals`), a category bar table (only if the inbox was read), sources (cited messages + events) and an approval block with id
  `AP-xxxxxx` when `propose_reply` ran. An inbound `APPROVE|REJECT <id>` reply (`parse_approval_reply`) resolves the stored proposal once
  (MOCK SEND logged; repeat -> "already decided", unknown -> "not found"). In-memory store, one process. Targets new Outlook/OWA; classic desktop out of scope.
  Without MOCK_M365 the old model-written HTML path is unchanged (no computed data there). Evidence: `.agent-runs/activity-ui-pilot/email-after/`.
- Baseline (pre-library) evidence: `.agent-runs/activity-ui-pilot/email-harness/`.

## Components as tools (ui-tools)
Chat turns give the model `UiToolkit` tools (`show_chart`, `show_figures`, `show_sources`, `propose_email`, `clear_components`)
plus `UI_INSTRUCTIONS`, on the real MCP path and on the mock path. No card is computed from tool data any more (the old
KPI/donut/`propose_reply` cards in `chat_turn` are gone; `MockSession`/`propose_reply` remain for the email path only).
Data-tool outputs are recorded for grounding (MCP `mcp_call` outputs by the adapter, mock outputs in `chat_turn.dispatch`);
an ungrounded value returns `Error: ...` to the model and renders nothing.
- `MOCK_M365_TEXT=1` (with `MOCK_M365=1`): mock tools return Work-IQ-like prose/markdown instead of JSON (chat path only).
- Approve: mock -> `MOCK SEND #n` log; real -> a Responses call with only `mcp_MailTools` sends the draft as the agent user
  (UNVERIFIED: tool name/deployed behaviour; logged as `MAIL SEND via mcp_MailTools`).
- Import: `chat_turn`/`email_turn` try the vendored `.m365_activity_ui` first, then a top-level install.
- Evidence: `.agent-runs/activity-ui-pilot/ui-tools/` (`drive.cjs`, screenshots a/b/c, `replay_ungrounded.txt`).
