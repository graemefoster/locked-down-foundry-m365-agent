"""Rich chat turn (progress lines, streamed markdown, KPI card, citations, follow-ups) over m365_activity_ui.

Used for non-email message activities. Email and notification paths keep the HTML single-message flow.
The library is optional: if it is not installed, ``available()`` is False and the host uses the old path.
"""
from __future__ import annotations

import json
import logging
import os
import re
from datetime import datetime
from typing import Any, AsyncIterator

logger = logging.getLogger(__name__)

try:  # vendored next to this module (deployed package, repo CI), else a top-level install (LOCAL_RUN.md)
    from .m365_activity_ui import (ApprovalDesk, CardInfo, FeedbackDesk, PromptDesk, ProgressTracker, TurnPresenter, UI_INSTRUCTIONS, UiToolkit,
                                   approval_card, citations, donut_chart, kpi_strip, present_responses,
                                   prompt_actions, with_actions)

    _LIB = True
except ImportError:
    try:
        from m365_activity_ui import (ApprovalDesk, CardInfo, FeedbackDesk, PromptDesk, ProgressTracker, TurnPresenter, UI_INSTRUCTIONS, UiToolkit,
                                      approval_card, citations, donut_chart, kpi_strip, present_responses,
                                      prompt_actions, with_actions)

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


SEND_CTX: dict[str, Any] = {}   # proposal id -> (agent, auth, handler, context) of the turn that proposed it


async def _send(prop: Any) -> None:
    """UiToolkit send callback, awaited once per Approve. Real path: the agent user's Mail MCP tool; mock: MOCK SEND."""
    if prop.get("demo"):
        logger.warning("DEMO approval %s approved: demo, not sent", prop["id"])
        return
    if os.getenv("MOCK_M365") == "1":
        SENT_LOG.append({"approval_id": prop["id"], "to": prop["to"], "subject": prop["subject"]})
        logger.warning("MOCK SEND #%d: to=%s subject=%r", len(SENT_LOG), prop["to"], prop["subject"])
        return
    agent, auth, handler, context = SEND_CTX.pop(prop["id"])
    mail = [t for t in await agent._build_mcp_tools(auth, handler, context) if t.get("server_label") == "mcp_MailTools"]
    if not mail:
        raise RuntimeError("Mail MCP tool unavailable; email not sent")
    cc = f"\nCc: {', '.join(prop['cc'])}" if prop.get("cc") else ""
    resp = await agent._openai_client.responses.create(
        model=agent._deployment, tools=mail,
        instructions="You send one email exactly as given, with the mail tool's send-email function, then reply 'sent'. "
                     "Do not change the subject or body. Do not add anything.",
        input=f"To: {', '.join(prop['to'])}{cc}\nSubject: {prop['subject']}\n\n{prop['body']}")
    calls = [(getattr(i, "name", ""), getattr(i, "error", None)) for i in resp.output if getattr(i, "type", "") == "mcp_call"]
    logger.warning("MAIL SEND via mcp_MailTools: to=%s subject=%r mcp_calls=%s", prop["to"], prop["subject"], calls)
    if not calls or any(err for _, err in calls):
        raise RuntimeError(f"Mail MCP send failed: {calls}")


import contextvars

RUN_PROMPT: Any = None                                   # set by register_approvals: run_prompt(context, prompt)
_FORM_CTX: contextvars.ContextVar = contextvars.ContextVar("form_invoke_context", default=None)


def _format_submission(values: dict, actor: str) -> str:
    return "I submitted the form with these values: " + "; ".join(f"{k}={v}" for k, v in values.items()) + "."


async def _on_form_submit(form_id: str, values: dict, actor: str) -> None:
    """FormDesk hook (once per form). Choice: the submitted values start a NEW USER TURN (the agent continues the task,
    e.g. proposes the invite email), run inline on the live invoke context captured by the wrapped ``handle`` below.
    Teams' invoke timeout is short: deployed, prefer a proactive context (unverified here, as for PromptDesk)."""
    ctx = _FORM_CTX.get()
    if form_id.startswith("demo-"):  # gallery form: reply deterministically, no model turn
        if ctx is not None:
            await ctx.send_activity("Demo, not booked. You submitted: " + "; ".join(f"{k}={v}" for k, v in values.items()))
        return
    logger.warning("FORM_SUBMIT form=%s actor=%s values=%s", form_id, actor, dict(values))
    if ctx is None or RUN_PROMPT is None:
        logger.warning("FORM_SUBMIT: no live context; no follow-up turn")
        return
    try:
        await RUN_PROMPT(ctx, _format_submission(values, actor))
    except Exception:
        logger.exception("form follow-up turn failed")


KIT: Any = UiToolkit(send=_send, on_form_submit=_on_form_submit) if _LIB else None
if _LIB:
    _orig_form_handle = KIT.forms.handle

    async def _form_handle(context: Any) -> Any:
        tok = _FORM_CTX.set(context)
        try:
            return await _orig_form_handle(context)
        finally:
            _FORM_CTX.reset(tok)

    KIT.forms.handle = _form_handle


def register_approvals(app: Any, run_prompt: Any = None, mode: str = "inline", app_id: str = "") -> None:
    """Register the invokes: ``prompt`` follow-up buttons (PromptDesk, ``inline`` or ``proactive``) and
    ``adaptiveCard/action`` (ApprovalDesk). ``run_prompt(context, prompt)`` runs the turn; PromptDesk echoes
    ``You asked: ...`` first."""
    if not _LIB:
        return
    global RUN_PROMPT
    RUN_PROMPT = run_prompt
    KIT.register(app)  # adaptiveCard/action: approvals (ApprovalDesk) + forms (FormDesk); sends once, replays no-ops
    FeedbackDesk().register(app)  # thumbs up/down invoke -> log line (default log_feedback)
    if run_prompt is not None:
        PromptDesk(run_prompt, mode=mode, app_id=app_id).register(app)


STEP_LABELS = {
    "list_messages": "Reading your inbox…",
    "get_message": "Opening an email…",
    "list_events": "Checking today's calendar…",
}

CHAT_FORMAT_RULES = (
    "- Format responses in Markdown (short headings, bullets). Never use HTML tags. Do not draw charts or tables of "
    "figures in text; use the component tools.\n"
    "- Whenever the user asks you to draft, write or reply to an email, you MUST call propose_email once with the full "
    "draft; never write the draft in your chat answer, never ask for confirmation first, and never lecture about tone: "
    "write it in the tone the user asked for (casual is fine), signed with your own name, FoundryDigitalWorker. "
    "Find the recipient's address in the mailbox (read it first if needed). The user approves it and the host sends "
    "it; never send email yourself with the mail tools. Then say the draft awaits their approval; never claim it was "
    "sent.\n"
    "- When the user asks to schedule/arrange a meeting (or needs several details from them), call show_form once "
    "(title, attendees, date, duration, agenda fields) instead of asking in text; their submission arrives as a new message.\n"
    "- For meeting attendees, call show_people with the people from the calendar tool results.\n"
    "- To summarise the inbox and day, read the mailbox and the calendar once each; to answer a count question one read "
    "is enough. State only counts that appear in tool results.\n"
) + UI_INSTRUCTIONS + "\n" if _LIB else ""


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


async def _event_stream(client: Any, request: dict, dispatch: Any, state: dict) -> AsyncIterator[Any]:
    """Chain streamed Responses rounds. MCP tools run server-side; function calls (UI tools, mock data tools) are
    dispatched here and their outputs fed back."""
    for _ in range(10):
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
        if not calls:
            return
        results = []
        for c in calls:
            out = await dispatch(c)
            results.append({"type": "function_call_output", "call_id": c.call_id, "output": out})
        request = {**request, "input": results, "previous_response_id": resp_id}


async def run_chat_turn(agent: Any, message: str, auth: Any, auth_handler_name: Any, context: Any) -> None:
    """One rich chat turn. Raises on failure (the presenter finishes with an error note). The model draws the cards
    by calling the UiToolkit tools on both paths (real MCP / mock); no card is computed from tool data."""
    agent._log_message_sender(context)
    response_input = await agent._prepare_response_input(message, context)
    conv = agent._get_conversation_id(context)
    mock = os.getenv("MOCK_M365") == "1"
    if mock:
        from mock_m365 import TOOL_SCHEMAS, call_tool

        tools = [t for t in TOOL_SCHEMAS if t["name"] != "propose_reply"]  # propose_email replaces it
    else:
        tools = await agent._build_mcp_tools(auth, auth_handler_name, context)
    tools = [*tools, *KIT.tools]
    instructions = agent._personalize_prompt(context).replace("- Format responses in html\n", CHAT_FORMAT_RULES)
    request: dict[str, Any] = {"model": agent._deployment, "instructions": instructions,
                               "input": response_input, "tools": tools}
    prev = agent._load_previous_response_id(conv)
    if prev:
        request["previous_response_id"] = prev

    state: dict[str, Any] = {}
    tracker = ProgressTracker(context, "Working on it…")
    await tracker.start()
    async with TurnPresenter(context, feedback=True, progress=tracker) as p:
        ui = KIT.turn(p)
        known = {id_ for id_ in KIT.proposals}

        async def dispatch(c: Any) -> str:
            if c.name in KIT.names:
                out = await ui.call(c.name, c.arguments)
                logger.info("UI_TOOL %s(%s) -> %s", c.name, c.arguments, out)
                for aid in KIT.proposals.keys() - known:  # remember who proposed it, for the real send
                    known.add(aid)
                    SEND_CTX[aid] = (agent, auth, auth_handler_name, context)
                return out
            if not mock:
                return f"Error: unknown tool {c.name!r}."
            logger.info("MOCK_M365 tool call: %s(%s)", c.name, c.arguments)
            out = call_tool(c.name, c.arguments)
            ui.record_output(out)  # grounding evidence (function outputs are not in the stream)
            return out

        p.step("Looking at your request…")  # visible at once; the model needs ~3s before its first tool call
        await present_responses(p, _event_stream(agent._openai_client, request, dispatch, state),
                                labels=STEP_LABELS, ui=ui)
        if state.get("response_id"):
            agent._save_response_id(conv, {"id": state["response_id"]})
