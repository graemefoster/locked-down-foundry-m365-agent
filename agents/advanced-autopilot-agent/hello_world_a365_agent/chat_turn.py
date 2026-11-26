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
    from microsoft_agents.activity import InvokeResponse
    from m365_activity_ui import (ApprovalDesk, CardInfo, PromptDesk, TurnPresenter, approval_card, citations, donut_chart,
                                  kpi_strip, present_responses, prompt_actions, with_actions)

    _LIB = True
except ImportError:  # pragma: no cover
    _LIB = False


def available() -> bool:
    return _LIB


MAX_CITES = 9
PENDING_APPROVALS: dict[str, dict] = {}   # approval_id -> draft (in-memory, one process)
SENT_LOG: list[dict] = []                 # mock sends; one entry per approved draft


def _decide(approval_id: str, approved: bool, actor: str) -> "CardInfo | None":
    """ApprovalDesk callback: called once per id. Approve logs a mock send; unknown id -> None (400)."""
    d = PENDING_APPROVALS.get(approval_id)
    if d is None:
        return None
    if approved:
        SENT_LOG.append({"approval_id": approval_id, "to": d["to"], "subject": d["subject"], "by": actor})
        logger.warning("MOCK SEND #%d: to=%s subject=%r approved_by=%s", len(SENT_LOG), d["to"], d["subject"], actor)
    else:
        logger.warning("MOCK SEND REJECTED: approval=%s by=%s (nothing sent)", approval_id, actor)
    return CardInfo(title=d["title"], summary=d["body"], details={"To": d["to"], "Subject": d["subject"]})


if _LIB:
    DESK = ApprovalDesk(_decide)


def register_approvals(app: Any, run_prompt: Any = None, inline: bool = False) -> None:
    """Register the invokes: ``prompt`` follow-up buttons and ``adaptiveCard/action`` (ApprovalDesk).

    ``run_prompt(context, prompt)`` runs the turn. Default (PromptDesk): it runs in a background task after the invoke
    ack, so it must not use the invoke context (closed). ``inline=True``: the turn is awaited inside the invoke handler
    on the live context (no ack until it finishes; fine locally, Teams invoke timeout is short)."""
    if not _LIB:
        return
    DESK.register(app)
    if run_prompt is None:
        return
    # Library-note: PromptDesk.register uses an `async def` selector; hosting-core 1.7 calls `route.selector(context)`
    # without awaiting, so the registered route never matches. Same wiring here with the sync `matches`.
    from microsoft_agents.activity import Activity, ActivityTypes
    from microsoft_agents.hosting.core.app._routes import RouteRank

    global PROMPTS
    PROMPTS = PromptDesk(run_prompt, echo=False)  # echo is sent by run_prompt, from a live context

    async def _on_prompt(context: Any, _state: Any) -> None:
        if inline:
            from m365_activity_ui.prompts import _prompt_of

            prompt = _prompt_of(context)
            if prompt is not None:
                await run_prompt(context, prompt)
                response = InvokeResponse(status=200, body={"statusCode": 200, "value": "OK",
                                                            "type": "application/vnd.microsoft.activity.message"})
            else:
                response = await PROMPTS.handle(context)
        else:
            response = await PROMPTS.handle(context)
        await context.send_activity(Activity(type=ActivityTypes.invoke_response, value=response))

    app.add_route(PROMPTS.matches, _on_prompt, is_invoke=True, rank=RouteRank.FIRST)


STEP_LABELS = {
    "list_messages": "Reading your inbox…",
    "get_message": "Opening an email…",
    "list_events": "Checking today's calendar…",
}

CHAT_FORMAT_RULES = (
    "- Format responses in Markdown (short headings, bullets). Never use HTML tags.\n"
    "- Some email tool results carry a `cite` number. Cite only emails that have one; when you state a fact from an email, "
    "cite it as [n] with that number (e.g. [3]). Do not invent numbers.\n"
    "- Every list_messages / list_events result has a `totals` object (messages_total, unread, urgent, meetings_today, "
    "conflicts) computed exactly over the whole mailbox and calendar. The KPI card shows these same numbers. "
    "Whenever you state a count of emails, unread, urgent, meetings or conflicts, quote `totals` verbatim; never count "
    "the rows you received, never estimate, and never state a total that is not in `totals`. "
    "`value` may be only a page of the data.\n"
    "- When asked to draft a reply, call propose_reply once with the full draft (fetch the email first if needed); "
    "it shows the user an approval card. Say the draft awaits their approval; never claim it was sent.\n"
    "- To summarise the inbox and day, call list_messages (top=30) and list_events once each; to answer a count question "
    "one call is enough.\n"
)


class MockSession:
    """Runs the mock function tools, numbers every email it returns (`cite`) and keeps results for KPIs."""

    def __init__(self) -> None:
        self.cite: dict[str, int] = {}
        self.messages: dict[str, dict] = {}
        self.events: list[dict] = []
        self.totals: dict[str, Any] | None = None
        self.drafts: list[dict] = []

    def run(self, name: str, arguments: str | None) -> str:
        if name == "propose_reply":
            a = json.loads(arguments or "{}")
            self.drafts.append({"to": a.get("to", ""), "subject": a.get("subject") or f"Re: {a.get('ref', '')}",
                                "body": a.get("body", ""), "ref": a.get("ref", "")})
            return json.dumps({"status": "shown_to_user_for_approval", "sent": False})
        from mock_m365 import call_tool

        data = json.loads(call_tool(name, arguments))
        if "totals" in data:
            self.totals = data["totals"]
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

    def chart(self) -> dict | None:
        cats = (self.totals or {}).get("unread_today_by_category") or {}
        if not cats:
            return None
        return donut_chart("Unread email by category, today, Alex's inbox",
                           [{"label": k.title(), "value": v} for k, v in cats.items()])

    def approval_cards(self) -> list[dict]:
        import uuid

        cards = []
        for d in self.drafts:
            aid = uuid.uuid4().hex
            d["title"] = f"Draft reply: {d['ref'] or d['subject']}"
            PENDING_APPROVALS[aid] = d
            cards.append(approval_card(aid, d["title"], d["body"], {"To": d["to"], "Subject": d["subject"]}))
        self.drafts = []
        return cards

    def card(self) -> dict | None:
        if not self.totals:
            return None
        t = self.totals  # same compute_totals() the model was handed in tool results
        return kpi_strip(
            [
                {"label": "Unread", "value": t["unread"], "tone": "accent"},
                {"label": "Urgent", "value": t["urgent"], "tone": "bad" if t["urgent"] else "good"},
                {"label": "Meetings today", "value": t["meetings_today"]},
                {"label": "Conflicts", "value": t["conflicts"], "tone": "warning" if t["conflicts"] else "good"},
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
            if card:  # follow-ups ride on the KPI card as imBack buttons (Teams hides suggestedActions beside cards)
                p.add_card(with_actions(card, prompt_actions(session.follow_ups())))
            chart = session.chart()
            if chart:
                p.add_card(chart)
            for ac in session.approval_cards():
                p.add_card(ac)
