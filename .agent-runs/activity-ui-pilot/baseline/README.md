# Baseline: today's turn in M365 Agents Playground (channel `msteams`)

Files: `activity_log.txt` + `inbound.jsonl` + `ws_frames.json` + `playground.png` = OK run (no-MCP, plain prompt).
`run1-proxy-blocked/`, `run2-mcp-400/` = failed runs (screenshots + frames). Repro: `agents/advanced-autopilot-agent/LOCAL_RUN.md`.
Capture: start `inbound_proxy.py` (:8091), point Playground at :8091, `node ../playground/drive.cjs "<prompt>" ../baseline` (after `npm install` in playground/).

## Turn (OK run, 19:40:51, handler 3.8 s)
- 19:40:51.004 IN message (channelId=msteams, no Authorization header, recipient = {id, name:"Test Bot"} — no `role`, no agentic app/user ids)
- +0.012 s OUT message "Working on your request."   (separate message, not an informative update)
- +0.019 s OUT typing                                 (loop interval 4 s; turn ended in 3.8 s so only 1 typing sent)
- +3.8 s  OUT message, one blob, 445 chars, wrapped in `<html><body><ul>…` — Playground renders the tags literally.
Also at conversation start: 2 greeting messages (installationUpdate/conversationUpdate).

## Agentic / streaming
Request is NOT agentic (anonymous, no agentic identity/role in recipient/from). channel_id=msteams, so the SDK
streaming gate on channel would pass, but the agentic gate blocks it for real M365 Copilot agent traffic. Locally,
streaming eligibility cannot be confirmed end-to-end (sample uses non-streaming `send_activity`, no StreamingResponse).

## Works
Local boot; Foundry project via `az login` (gpt-5.4-mini, Responses API, no tools); Playground round trip; 3.8 s turn.

## Blocked
1. `.env.local` HTTPS_PROXY → `ProxyError … host='localhost', port=8866 … Connection refused` on az token fetch
   (login.microsoftonline.com). Workaround: unset proxy vars.
2. MCP Mail/Calendar/Word/Excel/Teams/ODSP: `No bearer token available for MCP server mcp_MailTools (scope=ea9ffc3e-…/.default)`;
   Responses API → `400 {"error":{"message":"A user error occurred while executing a tool call.","code":"tool_user_error"}}`;
   user sees "I encountered an error processing your request. Status: 400". So "summarise my inbox" is blocked; plain prompt used with LOCAL_NO_MCP=1.
3. Checked-in `hello_world_a365_agent/.venv` has no python binary (stale) → rebuilt as `.venv-local`.
4. Notifications/auth handler (AGENTIC) unavailable: "No auth env vars; running anonymous".
