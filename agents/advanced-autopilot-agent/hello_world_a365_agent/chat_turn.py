"""Rich chat turn (progress lines, streamed markdown, KPI card, citations, follow-ups) over m365_activity_ui.

Used for non-email message activities. Email and notification paths keep the HTML single-message flow.
The library is optional: if it is not installed, ``available()`` is False and the host uses the old path.
"""
from __future__ import annotations

import json
import logging
import re
from datetime import datetime
from typing import Any, AsyncIterator

logger = logging.getLogger(__name__)

try:  # local editable install, see LOCAL_RUN.md
    from m365_activity_ui import TurnPresenter, citations, kpi_strip, present_responses

    _LIB = True
except ImportError:  # pragma: no cover
    _LIB = False


def available() -> bool:
    return _LIB


MAX_CITES = 9
STEP_LABELS = {
    "list_messages": "Reading your inbox…",
    "get_message": "Opening an email…",
    "list_events": "Checking today's calendar…",
}

CHAT_FORMAT_RULES = (
    "- Format responses in Markdown (short headings, bullets). Never use HTML tags.\n"
    "- Some email tool results carry a `cite` number. Cite only emails that have one; when you state a fact from an email, "
    "cite it as [n] with that number (e.g. [3]). Do not invent numbers.\n"
    "- To summarise the inbox call list_messages once with top=30 (the whole inbox), never a smaller number.\n"
)


class MockSession:
    """Runs the mock function tools, numbers every email it returns (`cite`) and keeps results for KPIs."""

    def __init__(self) -> None:
        self.cite: dict[str, int] = {}
        self.messages: dict[str, dict] = {}
        self.events: list[dict] = []

    def run(self, name: str, arguments: str | None) -> str:
        from mock_m365 import call_tool

        data = json.loads(call_tool(name, arguments))
        rows = data.get("value") if name == "list_messages" else ([data] if name == "get_message" else [])
        for m in rows or []:
            if "id" in m:
                self.messages[m["id"]] = {**self.messages.get(m["id"], {}), **m}
        # Teams/Playground accept at most MAX_CITES citations: number only the most important emails
        # (unread + high importance first); the model is told to cite only emails that carry `cite`.
        ranked = sorted(rows or [], key=lambda m: (m.get("isRead", True), m.get("importance") != "high"))
        for m in ranked:
            if "id" in m and (m["id"] in self.cite or len(self.cite) < MAX_CITES):
                m["cite"] = self.cite.setdefault(m["id"], len(self.cite) + 1)
        if name == "list_events":
            today = data.get("today", "")
            self.events = [e for e in data.get("value", []) if e["start"].startswith(today)] or self.events
        return json.dumps(data)

    # -- computed from tool results, never by the model ------------------------------------------
    def kpis(self) -> dict[str, Any]:
        msgs = list(self.messages.values())
        unread = [m for m in msgs if not m.get("isRead")]
        urgent = [m for m in unread if m.get("importance") == "high"]
        evs = sorted(self.events, key=lambda e: e["start"])
        conflicts = [(a, b) for i, a in enumerate(evs) for b in evs[i + 1:] if b["start"] < a["end"]]
        return {"unread": unread, "urgent": urgent, "events": evs, "conflicts": conflicts}

    def card(self) -> dict | None:
        k = self.kpis()
        if not self.messages and not self.events:
            return None
        return kpi_strip(
            [
                {"label": "Unread", "value": len(k["unread"]), "tone": "accent"},
                {"label": "Urgent", "value": len(k["urgent"]), "tone": "bad" if k["urgent"] else "good"},
                {"label": "Meetings today", "value": len(k["events"])},
                {"label": "Conflicts", "value": len(k["conflicts"]), "tone": "warning" if k["conflicts"] else "good"},
            ],
            title="Inbox and calendar at a glance",
        )

    def follow_ups(self) -> list[str]:
        k, out = self.kpis(), []
        for m in k["urgent"] or k["unread"]:
            ref = re.search(r"[A-Z]{2,}-\d+", m.get("subject", ""))
            out.append(f"Draft a reply to {ref.group(0) if ref else m.get('subject', 'this email')}")
            break
        for a, b in k["conflicts"][:1]:
            out.append(f"Resolve the {datetime.fromisoformat(b['start']).strftime('%H:%M')} conflict")
        if k["unread"]:
            out.append("Show only unread emails")
        return out[:3]

    def sources(self, text: str) -> list:
        used = [int(n) for n in re.findall(r"\[(\d+)\]", text)]
        by_n = {n: self.messages[i] for i, n in self.cite.items()}
        top = max([n for n in used if n in by_n], default=0)
        return citations(
            {"title": by_n[n].get("subject"), "url": by_n[n].get("webLink"), "content": by_n[n].get("bodyPreview")}
            for n in range(1, top + 1)
        )


async def _event_stream(client: Any, request: dict, session: MockSession | None, state: dict) -> AsyncIterator[Any]:
    """Chain streamed Responses rounds, running mock function tools between rounds."""
    for _ in range(8):
        calls: list[Any] = []
        resp_id = None
        async for ev in await client.responses.create(stream=True, **request):
            t = getattr(ev, "type", "")
            if t == "response.output_item.done" and getattr(ev.item, "type", "") == "function_call":
                calls.append(ev.item)
            elif t == "response.completed":
                resp_id = ev.response.id
                state["response_id"] = resp_id
            yield ev
        if not calls or session is None:
            return
        results = []
        for c in calls:
            logger.info("MOCK_M365 tool call: %s(%s)", c.name, c.arguments)
            results.append({"type": "function_call_output", "call_id": c.call_id,
                            "output": session.run(c.name, c.arguments)})
        request = {**request, "input": results, "previous_response_id": resp_id}


async def run_chat_turn(agent: Any, message: str, auth: Any, auth_handler_name: Any, context: Any) -> None:
    """One rich chat turn. Raises on failure (the presenter finishes with an error note)."""
    import os

    agent._log_message_sender(context)
    response_input = await agent._prepare_response_input(message, context)
    conv = agent._get_conversation_id(context)
    mock = os.getenv("MOCK_M365") == "1"
    if mock:
        from mock_m365 import TOOL_SCHEMAS

        tools, session = list(TOOL_SCHEMAS), MockSession()
    else:
        tools, session = await agent._build_mcp_tools(auth, auth_handler_name, context), None
    instructions = agent._personalize_prompt(context).replace("- Format responses in html\n", CHAT_FORMAT_RULES)
    request: dict[str, Any] = {"model": agent._deployment, "instructions": instructions,
                               "input": response_input, "tools": tools}
    prev = agent._load_previous_response_id(conv)
    if prev:
        request["previous_response_id"] = prev

    state: dict[str, Any] = {}
    async with TurnPresenter(context) as p:
        p.step("Looking at your request…")  # visible at once; the model needs ~3s before its first tool call
        streaming = p.streaming  # non-streaming channels (and agentic requests) get exactly one message
        await present_responses(p, _event_stream(agent._openai_client, request, session, state), labels=STEP_LABELS)
        if state.get("response_id"):
            agent._save_response_id(conv, {"id": state["response_id"]})
        if session is not None:
            text = p._text
            p.add_citations(session.sources(text))
            card = session.card()
            if card:
                p.add_card(card)
            p.suggest(session.follow_ups())
    # The library sends suggested prompts only on card-less turns (Teams hides suggestedActions beside
    # attachments). The pilot wants them next to the KPI card, so send them as a short follow-up message.
    prompts = session.follow_ups() if session is not None and session.card() and streaming else []
    if prompts:
        from microsoft_agents.activity import Activity

        await context.send_activity(Activity(
            type="message", text="Try next:",
            suggested_actions={"actions": [{"type": "imBack", "title": q[:100], "value": q} for q in prompts]}))
