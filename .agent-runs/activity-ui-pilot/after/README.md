# After: Playground turn with m365_activity_ui (msteams, MOCK_M365=1)
Prompt: "summarise my inbox and today's calendar". Files: activity_log.txt (ms since send), mid_turn.png (progress
line), final.png (card + follow-ups), frames/ (screenshot every ~450 ms), ws_frames.json, agent.log,
nonstream_slack.txt (1 message), nonstream_email.txt (HTML kept), drive_after.cjs, nonstream_check.py.
Timing vs baseline (baseline: first visible reply 3.8 s, an HTML blob; "Working on your request." at 0.01 s was a bare ack):
- first visible feedback: +0.57 s ("Looking at your request…"); tool-specific lines at +2.6 s / +3.6 s (the model needs ~2.5 s before its first tool call)
- streamed text from +4.6 s; final message (card + AI label + feedback) +5.7 s; follow-ups +6.7 s
- baseline had no tools; after includes two tool calls + one answer, so 5.7 s final is not like for like.
Notes: Playground shows [n] as plain text (citations are in aiEntity of the final frame, 20 -> capped 9);
model prose said "13 of 30 unread" while the card says 17 (fixture truth): card is computed, prose is not.
