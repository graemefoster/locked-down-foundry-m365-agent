# Email baseline (pre-library), 2026-11-27
Harness: agents/advanced-autopilot-agent/email_harness/send_email.py. Agent: own instance :8095, MOCK_M365=1 (demo agent on :8090 untouched).
Run: --from Alex --subject "What does my day look like?" -> HTTP 202 in 6.5 s, 2 outbound activities (typing + message with emailResponse),
reply body 894 chars of HTML; run/reply.html, run/reply_600.png (viewed at 600 px), run/summary.json.
Baseline reply: greeting "Hi,", one-line "4 meetings, 1 conflict", <ul> of 4 meetings with times, overlap sentence, offer to reschedule, "Best, FoundryDigitalWorker".
Plain, unstyled, no KPI/priorities/citations. No subject in the entity (Outlook derives "RE: ...").

## What the notification path calls
host_agent_server.on_notification (agents:* wildcard) -> FoundryDigitalWorkerAgent.handle_agent_notification_activity -> prompt
"You received a new email... return a response in html format. From: <id> Email details: <serialized notification>" -> _invoke_responses_api
(Foundry Responses API, one deployment, AGENT_PROMPT) -> model called list_events({"day":"today"}) (MOCK_M365 function tool), 2 Responses calls (~6 s).
-> EmailResponse.create_email_response_activity(text) -> context.send_activity. Reply is whatever the model emits (no HTML template, no sanitising).
MOCK_M365 covers it: same _invoke_responses_api path swaps MCP for mock list_messages/get_message/list_events. Log line still says "4 MCP tool server(s)" (cosmetic; the mock tools are used).
The model also sees raw model_dump of the notification, so sender/subject shape in the entity matters (subject only reaches it via htmlBody here).

## Negative check
--mode plain (channel msteams, same capture): 202, outbound kinds = ["text"], treated_as_email=false; goes to the chat turn (markdown "Your day at a glance"), no emailResponse entity (negative/run summary.json).
Not tested: agents:email without the entity (AgentNotificationActivity would hit NotificationTypes(activity.name) -> ValueError if name unset).

## Next-builder notes
No agent code changes needed. Gap: real Outlook payload (subject/from fields) unverified.
