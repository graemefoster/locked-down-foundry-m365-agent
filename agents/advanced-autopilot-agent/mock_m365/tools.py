"""Function-tool schemas (Responses API) + dispatcher over the generated mock fixture."""
from __future__ import annotations

import json
import os
from typing import Any

from .generate import generate

_DATA: dict | None = None


def _data() -> dict:
    global _DATA
    if _DATA is None:
        _DATA = generate()
    return _DATA


def compute_totals() -> dict[str, Any]:
    """The single source of inbox/calendar counts: tool results and the KPI card both use this."""
    d = _data()
    unread = [m for m in d["messages"] if not m["isRead"]]
    today = d["generated_for"]
    evs = sorted((e for e in d["events"] if e["start"].startswith(today)), key=lambda e: e["start"])
    conflicts = [(a, b) for i, a in enumerate(evs) for b in evs[i + 1:] if b["start"] < a["end"]]
    by_cat: dict[str, int] = {}
    for m in unread:
        if m["receivedDateTime"].startswith(today):
            by_cat[m["category"]] = by_cat.get(m["category"], 0) + 1
    return {"messages_total": len(d["messages"]), "unread": len(unread), "unread_today_by_category": by_cat,
            "urgent": sum(1 for m in unread if m["importance"] == "high"),
            "meetings_today": len(evs), "conflicts": len(conflicts)}


def _fn(name: str, description: str, props: dict[str, Any]) -> dict[str, Any]:
    return {"type": "function", "name": name, "description": description,
            "parameters": {"type": "object", "properties": props, "additionalProperties": False}}


TOOL_SCHEMAS: list[dict[str, Any]] = [
    _fn("propose_reply", "Propose a reply draft to an email. NOTHING is sent: the user gets an approval card with "
        "the draft and Approve/Reject buttons. Call once per draft, then tell the user the draft awaits approval.",
        {"ref": {"type": "string", "description": "ticket/subject reference, e.g. INC-5826"},
         "to": {"type": "string", "description": "recipient email address or name"},
         "subject": {"type": "string"}, "body": {"type": "string", "description": "the full draft reply text"}}),
    _fn("list_messages", "List inbox messages (newest first) with id, subject, sender, received time, importance, link.",
        {"top": {"type": "integer", "description": "max messages (default 30)"},
         "unread_only": {"type": "boolean"}}),
    _fn("get_message", "Get one inbox message in full, by id.", {"id": {"type": "string"}}),
    _fn("list_events", "List calendar events for today and tomorrow, with start/end, location, attendees, link.",
        {"day": {"type": "string", "enum": ["today", "tomorrow", "both"]}}),
]


def _prose(name: str, out: dict[str, Any]) -> str:
    """Work-IQ-like markdown/prose for a JSON tool result (MOCK_M365_TEXT=1): no JSON, no `totals` object."""
    if "error" in out:
        return f"Sorry, {out['error']}."
    if name == "list_messages":
        d = _data()
        unread = [m for m in d["messages"] if not m["isRead"]]
        cats: dict[str, int] = {}
        for m in unread:
            cats[m["category"]] = cats.get(m["category"], 0) + 1
        t = out["totals"]
        lines = [f"Your mailbox has {t['messages_total']} messages, {t['unread']} of them unread "
                 f"({t['urgent']} high-importance).",
                 "Unread messages by category: " + ", ".join(f"{k} {v}" for k, v in sorted(cats.items())) + ".", "",
                 "Messages (newest first):"]
        for m in out["value"]:
            lines.append(f"- {'(unread) ' if not m['isRead'] else ''}**{m['subject']}** from {m['from']['name']} "
                         f"<{m['from']['email']}>, {m['receivedDateTime'][:16].replace('T', ' ')}, "
                         f"importance {m['importance']}: {m['bodyPreview']} ({m['webLink']})")
        return "\n".join(lines)
    if name == "list_events":
        t = out["totals"]
        lines = [f"Calendar for {out['today']}: {t['meetings_today']} meetings today, {t['conflicts']} scheduling conflict(s).", ""]
        for e in out["value"]:
            lines.append(f"- **{e['subject']}** {e['start'][5:16].replace('T', ' ')} to {e['end'][11:16]} at "
                         f"{e['location']}, organiser {e['organizer']}, with {', '.join(e['attendees'])} ({e['webLink']})")
        return "\n".join(lines)
    if name == "get_message":
        return (f"**{out['subject']}**\nFrom: {out['from']['name']} <{out['from']['email']}>\n"
                f"Received: {out['receivedDateTime']}\n\n{out['body']}")
    return json.dumps(out)


def call_tool(name: str, arguments: str | dict | None) -> str:
    """JSON result, or prose when MOCK_M365_TEXT=1 (chat path only; the email path parses JSON)."""
    out = _call_json(name, arguments)
    if os.getenv("MOCK_M365_TEXT") == "1":
        return _prose(name, json.loads(out))
    return out


def _call_json(name: str, arguments: str | dict | None) -> str:
    args = json.loads(arguments) if isinstance(arguments, str) and arguments else (arguments or {})
    d = _data()
    if name == "list_messages":
        msgs = [m for m in d["messages"] if not (args.get("unread_only") and m["isRead"])]
        keys = ("id", "subject", "from", "receivedDateTime", "importance", "isRead", "conversationId", "bodyPreview", "webLink")
        out = [{k: m[k] for k in keys} for m in msgs[: int(args.get("top") or 30)]]
        return json.dumps({"totals": compute_totals(), "value": out})
    if name == "get_message":
        m = next((m for m in d["messages"] if m["id"] == args.get("id")), None)
        return json.dumps(m or {"error": f"message {args.get('id')} not found"})
    if name == "list_events":
        day = args.get("day") or "both"
        evs = d["events"]
        today = d["generated_for"]
        if day == "today":
            evs = [e for e in evs if e["start"].startswith(today)]
        elif day == "tomorrow":
            evs = [e for e in evs if not e["start"].startswith(today)]
        return json.dumps({"today": today, "totals": compute_totals(), "value": evs})
    return json.dumps({"error": f"unknown tool {name}"})
