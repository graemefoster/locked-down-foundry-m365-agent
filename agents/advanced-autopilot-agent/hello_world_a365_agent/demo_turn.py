"""`demo` command: a deterministic gallery of every m365_activity_ui component with sample data.

No model call, no Work IQ / mailbox call. Each component goes out as its own message (no attachment cap hit: a
message carries one card; only the closing message has citations + prompt buttons). Works the same in Teams and Playground.
Commands: ``demo`` (all), ``demo charts|figures|table|people|form|approval|sources|progress``; also ``/demo`` and
``show me a demo``.
"""
from __future__ import annotations

import asyncio
import logging
import re
import uuid
from typing import Any

from microsoft_agents.activity import Activity, Attachment

from . import chat_turn as ct
from .m365_activity_ui import ADAPTIVE_CARD_CONTENT_TYPE, ProgressTracker, TurnPresenter, citations

logger = logging.getLogger(__name__)

SAMPLE = "Sample data"
_PAT = re.compile(r"^\s*/?demo(?:\s+(charts?|figures?|table|people|form|approval|sources?|progress))?\s*[.!]?\s*$"
                  r"|^\s*show me a demo\s*[.!]?\s*$", re.I)
SECTIONS = ("progress", "charts", "figures", "table", "people", "form", "approval", "sources")


def parse(text: str) -> str | None:
    """'all' | a section name when ``text`` is a demo command, else None."""
    m = _PAT.match(text or "")
    if not m:
        return None
    sec = (m.group(1) or "all").lower()
    return {"chart": "charts", "figure": "figures", "source": "sources"}.get(sec, sec)


async def _send_card(context: Any, card: dict, label: str) -> None:
    card = {**card, "body": [{"type": "TextBlock", "text": f"{SAMPLE} · {label}", "size": "Small", "isSubtle": True,
                              "wrap": True}, *card.get("body", [])]}
    await context.send_activity(Activity(type="message", attachments=[
        Attachment(content_type=ADAPTIVE_CARD_CONTENT_TYPE, content=card)]))
    logger.info("demo card sent: %s", label)


async def _progress(context: Any) -> None:
    steps = ["Reading sample inbox", "Checking sample calendar", "Drawing sample components"]
    t = ProgressTracker(context, f"{SAMPLE}: working on it…", steps)
    await t.start()
    for s in steps:
        await t.astep(s)
        await asyncio.sleep(0.9)
    await t.finish()


async def _charts(context: Any) -> None:
    from .m365_activity_ui import (bar_chart, donut_chart, gauge_chart, horizontal_bar_chart, line_chart, pie_chart)
    cat = [{"label": k, "value": v} for k, v in (("Urgent", 4), ("Thread", 6), ("FYI", 6), ("Newsletter", 1))]
    week = [{"label": d, "value": v} for d, v in (("Mon", 12), ("Tue", 18), ("Wed", 9), ("Thu", 15), ("Fri", 7))]
    for label, card in (("bar chart", bar_chart("Unread by category", cat)),
                        ("horizontal bar chart", horizontal_bar_chart("Unread by category", cat)),
                        ("line chart", line_chart("Emails received this week", week)),
                        ("pie chart", pie_chart("Email by sender", [{"label": k, "value": v} for k, v in
                                                                     (("Marcus Lee", 5), ("Elena Petrova", 4),
                                                                      ("Sofia Alvarez", 3), ("Daniel Kim", 3))])),
                        ("donut chart", donut_chart("Unread by category", cat)),
                        ("gauge", gauge_chart("Inbox zero progress", 68, target=90))):
        await _send_card(context, card, label)


async def _figures(context: Any) -> None:
    from .m365_activity_ui import kpi_strip
    await _send_card(context, kpi_strip([
        {"label": "Unread", "value": 17, "tone": "accent"}, {"label": "Urgent", "value": 4, "tone": "bad"},
        {"label": "Meetings today", "value": 4}, {"label": "Conflicts", "value": 1, "tone": "warning"}],
        title="Inbox and calendar at a glance"), "figures card")


async def _table(context: Any) -> None:
    from .m365_activity_ui import table_card
    rows = [("Fri 27 Nov", "09:30-09:45", "Team standup", "Sofia Alvarez"),
            ("Fri 27 Nov", "11:00-12:00", "Launch readiness review", "Daniel Kim"),
            ("Sat 28 Nov", "10:00-11:00", "Budget variance session", "Priya Nair")]
    links = [f"https://outlook.office.com/calendar/item/DEMO-{i}" for i in range(1, 4)]
    await _send_card(context, table_card("Meetings this week", ["Date", "Time", "Meeting", "Organiser"], rows, links=links),
                     "table with links")


async def _people(context: Any) -> None:
    from .m365_activity_ui import people_card
    await _send_card(context, people_card("Attendees in the next meeting", [
        {"name": "Daniel Kim", "email": "daniel.kim@contoso.example", "role": "Organiser"},
        {"name": "Tom Becker", "email": "tom.becker@contoso.example", "role": "Attendee"},
        {"name": "Priya Nair", "email": "priya.nair@contoso.example", "role": "Attendee"}]), "people card")


async def _form(context: Any) -> None:
    form_id = "demo-" + uuid.uuid4().hex[:8]
    card = ct.KIT.forms.form(form_id, "Schedule a meeting (demo)", [
        {"id": "title", "kind": "text", "label": "Title", "required": True, "value": "Roadmap sync"},
        {"id": "attendees", "kind": "multichoice", "label": "Attendees", "required": True,
         "choices": ["Daniel Kim", "Tom Becker", "Priya Nair"], "value": ["Priya Nair"]},
        {"id": "when", "kind": "choice", "label": "When", "required": True,
         "choices": ["Tomorrow 10:00", "Tomorrow 14:00", "Monday 09:30"], "value": "Tomorrow 14:00"},
        {"id": "minutes", "kind": "number", "label": "Duration (minutes)", "value": 30},
    ], "Schedule")
    await _send_card(context, card, "form (submit it: nothing is booked)")


async def _approval(context: Any) -> None:
    aid = "demo-" + uuid.uuid4().hex[:8]
    prop = {"id": aid, "to": ["demo@example.invalid"], "cc": [], "demo": True,
            "subject": "[DEMO, not sent] Quarterly update", "body": "This is sample text. Approving it sends nothing."}
    ct.KIT.proposals[aid] = prop
    await _send_card(context, ct.KIT.pending_card(prop), "approval card (edit the body; approving sends nothing)")


async def _closing(context: Any, sources: bool = True) -> None:
    async with TurnPresenter(context, feedback=True) as p:
        p.step("Wrapping up…")
        await asyncio.sleep(0.3)
        if sources:
            p.text("Sample sources for this demo: the policy page [1] and the launch checklist [2]. ")
            p.add_citations(citations([
                {"title": "Sample: Travel policy", "url": "https://example.com/policy", "content": "Sample snippet one."},
                {"title": "Sample: Launch checklist", "url": "https://example.com/checklist",
                 "content": "Sample snippet two."}]))
        p.text("That is the demo. Everything here used sample data, no mailbox or model call. Try the buttons.")
        p.suggest(["demo charts", "demo table", "demo form", "What's in my inbox today?"])


async def run_demo(context: Any, section: str) -> None:
    logger.warning("DEMO command section=%s (no model call)", section)
    todo = SECTIONS if section == "all" else (section,)
    if section == "all":
        await context.send_activity(f"**Demo mode.** Every component below uses **{SAMPLE}**: no mailbox, no model. "
                                    "Each card is its own message. Try `demo charts`, `demo table`, `demo people`, "
                                    "`demo form`, `demo approval` to see one at a time.")
    fns = {"progress": _progress, "charts": _charts, "figures": _figures, "table": _table, "people": _people,
           "form": _form, "approval": _approval}
    for s in todo:
        if s == "sources":
            continue
        await fns[s](context)
    if section in ("all", "sources"):
        await _closing(context)
    elif section == "progress":
        pass
