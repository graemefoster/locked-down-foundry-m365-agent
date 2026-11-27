"""Email-notification replies composed with ``m365_activity_ui.email`` (mock-tool mode).

The model writes only the prose (markdown). Code adds the blocks from computed data: figures (``compute_totals``),
bars (``unread_today_by_category``), sources (messages/events the tools returned) and an approval block when
``propose_reply`` produced a draft. An inbound ``APPROVE <id>`` / ``REJECT <id>`` reply is parsed with
``parse_approval_reply`` and resolves the stored proposal once (first decision wins). Chat path is untouched.
Target: new Outlook / OWA. Classic Outlook desktop is out of scope.
"""
from __future__ import annotations

import html
import logging
import os
import re
import uuid
from typing import Any

from . import chat_turn

logger = logging.getLogger(__name__)

try:
    from m365_activity_ui import (approval_block, bar_table, email_reply, figures_table, parse_approval_reply,
                                  reply_top, sources_footnotes)

    _LIB = True
except ImportError:  # pragma: no cover
    _LIB = False

SIGN_OFF = "Your inbox agent"
DECIDED: dict[str, dict] = {}  # approval_id -> {"verdict", "by"}; first decision wins (same rule as ApprovalDesk)

EMAIL_FORMAT_RULES = (
    "- You are replying by email. Write the reply as short Markdown prose only: a greeting, then a few sentences or "
    "bullets. Never use HTML tags and never write a table of figures: the system adds a figures table, a category "
    "chart, a sources list and any approval block itself from the tool data.\n"
    "- Some email tool results carry a `cite` number. Cite only emails that have one, as [n] with that number. "
    "Do not invent numbers; never write other bracketed words. No backticks, no field names such as `unread_today_by_category`; say it in plain words.\n"
    "- Every list_messages / list_events result has a `totals` object computed exactly over the whole mailbox and "
    "calendar. Whenever you state a count, quote `totals` verbatim; never count rows or estimate.\n"
    "- Your own reply to the sender is the Markdown you write; it is not a draft. Call propose_reply only when the "
    "sender asks you to draft a reply to a particular email, and then once only: call propose_reply once with the full draft (fetch the email first if needed). "
    "Say the draft awaits approval by reply; never claim it was sent. Do not write the approval instructions "
    "yourself.\n"
    "- Call only the tools the question needs. For a summary, answer in prose: never call propose_reply for a summary, and never draft a reply to the sender. Calendar or day-schedule questions: call list_events only (do not read the "
    "inbox). Inbox questions: list_messages (top=30), plus list_events only if the sender also asks about meetings. "
    "To draft a reply to an email named by reference (for example INC-5826), call list_messages once to find it, then "
    "get_message with its real id, then propose_reply; do not call list_events.\n"
)


def available() -> bool:
    return _LIB and os.getenv("MOCK_M365") == "1"


# ---- approval store -------------------------------------------------------------------------------------------
def _store_drafts(session: chat_turn.MockSession) -> list[tuple[str, dict]]:
    out = []
    for d in session.drafts:
        aid = "AP-" + uuid.uuid4().hex[:6]
        d["title"] = f"Draft reply: {d['ref'] or d['subject']}"
        chat_turn.PENDING_APPROVALS[aid] = d
        out.append((aid, d))
    session.drafts = []
    return out


def _with_line_breaks(block: Any, summary: str) -> Any:
    """The library escapes the summary and drops newlines; re-render the (already escaped) body with <br>."""
    esc = html.escape(summary, quote=True)
    if "\n" not in summary or esc not in block.html:
        return block
    br = "<br>".join(html.escape(ln, quote=True) for ln in summary.replace("\r\n", "\n").split("\n"))
    return block._replace(html=block.html.replace(esc, br, 1))


def _compose_blocks(session: chat_turn.MockSession, text: str, tools: set[str]) -> list:
    blocks = []
    drafting = "propose_reply" in tools  # a draft reply shows only prose + approval block (the lookups were a means)
    t = None if drafting else session.totals
    if t and tools & {"list_messages", "list_events"}:
        blocks.append(figures_table([
            {"label": "Unread", "value": t["unread"], "tone": "accent"},
            {"label": "Urgent", "value": t["urgent"], "tone": "bad" if t["urgent"] else "good"},
            {"label": "Meetings today", "value": t["meetings_today"]},
            {"label": "Conflicts", "value": t["conflicts"], "tone": "warning" if t["conflicts"] else "good"},
        ], title="Inbox and calendar at a glance"))
        cats = t.get("unread_today_by_category") or {}
        if cats and "list_messages" in tools:  # only when the inbox was listed this turn
            blocks.append(bar_table("Unread email by category, today",
                                    [{"label": k.title(), "value": v} for k, v in cats.items()]))
    used = [int(n) for n in re.findall(r"\[(\d+)\]", text)]
    by_n = {n: session.messages[i] for i, n in session.cite.items()}
    top = max([n for n in used if n in by_n], default=0)
    items = [{"title": by_n[n].get("subject"), "url": by_n[n].get("webLink")} for n in range(1, top + 1)]
    items += [{"title": f"Calendar: {e.get('subject')}", "url": e.get("webLink")} for e in session.events]
    if items and not drafting:
        blocks.append(sources_footnotes(items))
    for aid, d in _store_drafts(session):
        blocks.append(_with_line_breaks(
            approval_block(aid, d["title"], d["body"], {"To": d["to"], "Subject": d["subject"]}), d["body"]))
    return blocks


# ---- model turn -------------------------------------------------------------------------------------------------
async def run_email_turn(agent: Any, message: str, conversation_id: str, context: Any) -> str:
    """Non-streaming Responses loop with the mock tools; returns the composed HTML."""
    from mock_m365 import TOOL_SCHEMAS

    session = chat_turn.MockSession()
    tools: set[str] = set()  # tools actually called this turn
    instructions = (agent._personalize_prompt(context)
                    .replace("- Format responses in html\n", EMAIL_FORMAT_RULES)
                    .replace("return your reply directly in HTML format", "return your reply as Markdown prose"))
    args: dict[str, Any] = {"model": agent._deployment, "instructions": instructions, "input": message,
                            "tools": list(TOOL_SCHEMAS)}
    prev = agent._load_previous_response_id(conversation_id)
    if prev:
        args["previous_response_id"] = prev
    resp = await agent._openai_client.responses.create(**args)
    for _ in range(8):
        calls = [i for i in resp.output if getattr(i, "type", "") == "function_call"]
        if not calls:
            break
        results = []
        for c in calls:
            if c.name == "propose_reply" and not re.search(r"\b(draft|propose)\b", message, re.IGNORECASE):
                results.append({"type": "function_call_output", "call_id": c.call_id,
                                "output": '{"error": "not requested: the sender did not ask for a draft. Answer in prose."}'})
                continue  # a summary question never produces a draft/approval card
            tools.add(c.name)
            logger.info("MOCK_M365 tool call: %s(%s)", c.name, c.arguments)
            results.append({"type": "function_call_output", "call_id": c.call_id,
                            "output": session.run(c.name, c.arguments)})
        resp = await agent._openai_client.responses.create(
            model=agent._deployment, instructions=instructions, tools=list(TOOL_SCHEMAS), input=results,
            previous_response_id=resp.id)
    agent._save_response_id(conversation_id, {"id": resp.id})
    prose = re.sub(r"\s*\[[A-Za-z_ ]+\]", "", (resp.output_text or "").replace("`", ""))  # stray non-numeric markers like [totals]
    html, text = email_reply(None, prose, _compose_blocks(session, prose, tools), SIGN_OFF)
    logger.info("email reply (text twin):\n%s", text)
    return html


# ---- inbound APPROVE / REJECT -----------------------------------------------------------------------------------
_CMD = re.compile(r"(APPROVE|REJECT)\s+([A-Za-z0-9_.-]{1,64}?)\.?", re.IGNORECASE)


def _top_without_subject(html_body: str) -> str:
    lines = [ln for ln in reply_top(html_body).splitlines()]
    while lines and (not lines[0].strip() or lines[0].strip().lower().startswith("subject:")):
        lines.pop(0)
    return "\n".join(lines)


def approval_command(html_body: str) -> tuple[str, str] | None:
    """(verb, id) when the new top of the reply is exactly ``APPROVE|REJECT <id>``, else None (normal email)."""
    if not _LIB or not html_body:
        return None
    top = _top_without_subject(html_body)
    first = next((ln.strip() for ln in top.splitlines() if ln.strip()), "")
    m = _CMD.fullmatch(first)
    if not m:
        return None
    verdict = parse_approval_reply(top, m.group(2))  # the library's strict parse decides
    return (verdict, m.group(2)) if verdict else None


def html_body_of(activity: Any) -> str:
    """``htmlBody`` of the emailNotification entity on an activity, else ''."""
    for ent in getattr(activity, "entities", None) or []:
        d = ent.model_dump(by_alias=True) if hasattr(ent, "model_dump") else dict(ent)
        if str(d.get("type", "")).lower() == "emailnotification":
            return d.get("htmlBody") or d.get("html_body") or ""
    return ""


def _reply(prose: str, blocks: list | None = None) -> str:
    return email_reply(None, prose, blocks or [], SIGN_OFF)[0]


def resolve_by_email(verb: str, aid: str, actor: str) -> str:
    """Resolve once. Returns the reply HTML. Unknown id -> not found; repeat -> already decided (no send)."""
    draft = chat_turn.PENDING_APPROVALS.get(aid)
    if draft is None:
        return _reply(f"I could not find a pending proposal with id **{aid}**. Nothing was sent. "
                      "Please check the id in my original email.")
    prior = DECIDED.get(aid)
    if prior is not None:
        return _reply(f"Proposal **{aid}** was already decided ({prior['verdict']} by {prior['by']}). "
                      "No further action was taken and nothing more was sent.")
    DECIDED[aid] = {"verdict": "approved" if verb == "approve" else "rejected", "by": actor}
    chat_turn._decide(aid, verb == "approve", actor)  # logs MOCK SEND #n on approve
    details = {"To": draft["to"], "Subject": draft["subject"]}
    if verb == "approve":
        blk = figures_table([{"label": k, "value": v} for k, v in details.items()], title="Sent (mock)")
        return _reply(f"Approved: **{draft['title']}** ({aid}) has been sent.", [blk])
    return _reply(f"Rejected: **{draft['title']}** ({aid}). Nothing was sent.")
