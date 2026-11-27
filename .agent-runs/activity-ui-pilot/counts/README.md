# R5 numbers agree: prose vs card vs computed totals

## Root cause
- Fixture holds 25 messages (17 unread, 4 urgent). The "30" came from our own prompt/schema: CHAT_FORMAT_RULES said
  "call list_messages with top=30 (the whole inbox)" and the tool schema says "default 30", so the model treated 30 as the
  inbox size. "13 of 30 unread" was the model counting rows/estimating; tool results carried no totals.
- The KPI card was computed from whichever rows the model happened to fetch (`MockSession.messages`), so a top=10 call
  would also have made the card wrong.

## Fix
- `mock_m365.tools.compute_totals()` is the one source (whole fixture). Every `list_messages` / `list_events` result carries
  `totals` {messages_total, unread, urgent, meetings_today, conflicts}; the KPI card reads the same dict from the tool result.
- Chat instructions: quote `totals` verbatim, never count rows or estimate; `value` may be a page.

## Real local turns (Playground -c msteams, MOCK_M365=1, fresh store per turn; turnN/ has ws_frames, page_text, agent.log)
| turn | prompt | total msgs | unread | urgent | meetings | conflicts |
|---|---|---|---|---|---|---|
| computed | - | 25 | 17 | 4 | 4 | 1 |
| 1 | summarise my inbox and today's calendar | prose 25 | prose 17 | prose 4 | prose 4 | prose 1 |
| 1 card | | - | 17 | 4 | 4 | 1 |
| 2 | how many urgent emails do I have? | - | - | prose 4 ("You have 4 urgent emails.") | - | - |
| 2 card | | - | 17 | 4 | 4 | 1 |
| 3 | summarise my inbox and today's calendar | prose 25 | prose 17 | prose 4 | prose 4 | prose 1 |
| 3 card | | - | 17 | 4 | 4 | 1 |

All prose numbers equal the card and computed totals. Not verified: other prompts (e.g. "emails from last week"), non-mock MCP path
(unchanged; has no totals), model nondeterminism beyond 3 samples. Turn 1 first attempt crashed in the driver (wrong script), rerun used drive_after.cjs.
Files: run_turn.sh (one turn), extract.py (prose/card/totals).
