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
3. Playground (set `-c msteams` to match Teams channel behaviour):
   `npx @microsoft/m365agentsplayground -p 56170 -e http://localhost:8090/api/messages -c msteams`
   then open http://localhost:56170. (Port 8088/56150 may be taken by other local agents.)
4. Timestamped capture: `.agent-runs/activity-ui-pilot/baseline/inbound_proxy.py` (inbound, :8091 -> :8090)
   and `.agent-runs/activity-ui-pilot/playground/drive.cjs` (UI driver, records outbound frames + screenshot).
   See `.agent-runs/activity-ui-pilot/baseline/README.md`.

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
