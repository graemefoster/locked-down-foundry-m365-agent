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
