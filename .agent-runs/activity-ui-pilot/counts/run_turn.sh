#!/bin/bash
# Usage: run_turn.sh <n> "<prompt>"   (from repo root). Fresh agent + fresh response store per turn.
set -u
R=$(pwd); N=$1; P=$2; O=$R/.agent-runs/activity-ui-pilot/counts/turn$N
mkdir -p "$O"
cd "$R/agents/advanced-autopilot-agent"
set -a; . hello_world_a365_agent/.env.local; set +a
unset HTTPS_PROXY HTTP_PROXY REQUESTS_CA_BUNDLE CA_CERTS SSL_CERT_FILE
RESPONSE_STORE_DIR=$(mktemp -d) PORT=8090 MOCK_M365=1 hello_world_a365_agent/.venv-local/bin/python local_run.py >"$O/agent.log" 2>&1 &
A=$!
cd "$R"
(cd /tmp && npx --yes @microsoft/m365agentsplayground -p 56170 -e http://localhost:8090/api/messages -c msteams >"$O/playground.log" 2>&1) &
for i in $(seq 1 40); do curl -s -o /dev/null localhost:56170 && curl -s -o /dev/null localhost:8090 && break; sleep 1; done
cd "$R/.agent-runs/activity-ui-pilot/after" && timeout 200 node drive_after.cjs "$P" "$O"
kill $A
lsof -ti :56170 | xargs kill 2>/dev/null
echo done
