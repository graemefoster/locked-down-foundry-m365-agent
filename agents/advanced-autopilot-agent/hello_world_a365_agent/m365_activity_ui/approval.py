"""Approve/reject Adaptive Cards that update in place (Universal Actions), plus the invoke handler.

Analogue of the AgentCraft web ActionBoard ``onApprove`` (libraries/frontend-ui).

How the SDK delivers a click (microsoft-agents-hosting-core 1.7):
  * An ``Action.Execute`` click arrives as an ``invoke`` activity named ``adaptiveCard/action``;
    ``activity.value`` is an ``AdaptiveCardInvokeValue`` dict: ``{"action": {"type": "Action.Execute",
    "verb": "approve", "data": {"approval_id": ...}}}``.
  * Register with ``@app.invoke("adaptiveCard/action")`` (``AgentApplication.invoke``), or with the SDK's
    ``app.adaptive_card.action_execute("approve")`` which validates and unpacks for you.
  * The reply is an activity of type ``invokeResponse`` whose ``value`` is an ``InvokeResponse(status, body)``;
    for a card the body is ``{"statusCode": 200, "type": "application/vnd.microsoft.card.adaptive",
    "value": <card>}`` and Teams/Copilot replaces the card in place.

``ApprovalDesk.handle`` does the decoding and returns that ``InvokeResponse``; ``ApprovalDesk.register``
wires it onto an ``AgentApplication`` and sends it::

    desk = ApprovalDesk(decide)            # decide(approval_id, approved, actor) -> CardInfo | None
    desk.register(app)
    await context.send_activity(Activity(type="message", attachments=[card_attachment(approval_card(...))]))
"""
from __future__ import annotations

import asyncio
import inspect
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable, Mapping, Sequence

from microsoft_agents.activity import Activity, ActivityTypes, InvokeResponse

from .cards import ADAPTIVE_CARD_CONTENT_TYPE, adaptive_card

ERROR_CONTENT_TYPE = "application/vnd.microsoft.error"
INVOKE_NAME = "adaptiveCard/action"
VERBS = ("approve", "reject")


@dataclass(frozen=True)
class CardInfo:
    """What the decision callback returns: the card text to show once resolved (None from the callback = unknown id)."""
    title: str
    summary: str = ""
    details: Mapping[str, Any] | None = None
    edited: bool = False          # approver changed editable fields: the resolved card says so


class ApprovalInputError(Exception):
    """Raised by ``decide`` when submitted edits are invalid: the desk answers with ``card`` (the pending card plus an
    error line, nothing decided) so the approver can fix the input and press Approve again."""

    def __init__(self, message: str, card: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.card = card


Decide = Callable[[str, bool, str], "CardInfo | None | Awaitable[CardInfo | None]"]


def _facts(details: Mapping[str, Any] | None) -> list[dict[str, Any]]:
    if not details:
        return []
    return [{"type": "FactSet", "facts": [{"title": str(k), "value": str(v)} for k, v in details.items()]}]


def _action(title: str, verb: str, approval_id: str, style: str | None = None) -> dict[str, Any]:
    act: dict[str, Any] = {"type": "Action.Execute", "title": title, "verb": verb, "data": {"approval_id": approval_id}}
    if style:
        act["style"] = style
    return act


def approval_card(id: str, title: str, summary: str, details: Mapping[str, Any] | None = None,
                  approve_label: str = "Approve", reject_label: str = "Reject",
                  editable: Sequence[Mapping[str, Any]] | None = None, error: str | None = None) -> dict[str, Any]:
    """Pending card: title, summary, optional read-only facts, optional editable ``Input.Text`` fields, Approve/Reject
    ``Action.Execute`` (verbs ``approve``/``reject``, data ``{approval_id}``; the client adds each input's value keyed
    by its id) and a ``refresh`` so clients re-fetch the current state (the resolved card once decided).

    ``editable``: ``[{"id", "label", "value", "multiline": bool, "max_length": int}]``; standard Adaptive Card
    ``Input.Text`` + ``Action.Execute``, the same in Teams and M365 Copilot (no surface detection). Ids must not be
    ``approval_id``. ``error`` adds a red line (used when re-rendering after invalid edits)."""
    body: list[dict[str, Any]] = [
        {"type": "TextBlock", "text": title, "weight": "Bolder", "size": "Medium", "wrap": True},
        {"type": "TextBlock", "text": summary, "wrap": True},
        *_facts(details),
    ]
    if error:
        body.append({"type": "TextBlock", "text": error, "color": "Attention", "wrap": True})
    for f in editable or ():
        if f["id"] == "approval_id":
            raise ValueError("editable field id must not be approval_id")
        inp: dict[str, Any] = {"type": "Input.Text", "id": f["id"], "label": f.get("label", f["id"]),
                               "isMultiline": bool(f.get("multiline")), "value": str(f.get("value", ""))}
        if f.get("max_length"):
            inp["maxLength"] = int(f["max_length"])
        body.append(inp)
    card = adaptive_card(body)
    card["actions"] = [_action(approve_label, "approve", id, "positive"), _action(reject_label, "reject", id, "destructive")]
    card["refresh"] = {"action": _action("Refresh", "refresh", id), "userIds": []}
    return card


def resolved_card(title: str, summary: str, details: Mapping[str, Any] | None, *, approved: bool, by: str,
                  when: datetime | str, edited: bool = False) -> dict[str, Any]:
    """Resolved card: same content, no actions, a coloured outcome line (who and when, UTC); ``edited`` appends
    "(edited before sending)" to an approval."""
    stamp = when.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M UTC") if isinstance(when, datetime) else str(when)
    verdict = "Approved" if approved else "Rejected"
    return adaptive_card([
        {"type": "TextBlock", "text": title, "weight": "Bolder", "size": "Medium", "wrap": True},
        {"type": "TextBlock", "text": summary, "wrap": True},
        *_facts(details),
        {"type": "TextBlock", "text": f"{verdict}{' (edited before sending)' if edited and approved else ''} by {by} on {stamp}", "weight": "Bolder",
         "color": "Good" if approved else "Attention", "wrap": True},
    ])


def _card_response(card: dict[str, Any]) -> InvokeResponse:
    return InvokeResponse(status=200, body={"statusCode": 200, "type": ADAPTIVE_CARD_CONTENT_TYPE, "value": card})


def _error_response(message: str) -> InvokeResponse:
    return InvokeResponse(status=400, body={"statusCode": 400, "type": ERROR_CONTENT_TYPE,
                                            "value": {"code": "BadRequest", "message": message}})


def _takes_inputs(fn: Callable[..., Any]) -> bool:
    """True when ``fn`` accepts a 4th positional argument (the card's submitted input values)."""
    try:
        ps = list(inspect.signature(fn).parameters.values())
    except (TypeError, ValueError):
        return False
    return any(p.kind == p.VAR_POSITIONAL for p in ps) or \
        sum(p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD) for p in ps) >= 4


@dataclass
class ApprovalDesk:
    """Handles ``adaptiveCard/action`` invokes for approval cards.

    ``decide(approval_id, approved, actor[, inputs])`` (sync or async; ``inputs`` = the editable fields' submitted
    values, only on Approve, only if ``decide`` takes a 4th argument; raise ``ApprovalInputError`` to refuse them) records the decision and returns ``CardInfo``, or
    ``None`` for an unknown approval id. It is called at most once per id: the first decision wins, later clicks
    (double click, other approver) get the resolved card back without calling it. Resolutions live in memory
    (one process); persist them in the callback's store if the agent scales out.
    """
    decide: Decide
    clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc)
    _resolved: dict[str, dict[str, Any]] = field(default_factory=dict, init=False, repr=False)
    _locks: dict[str, asyncio.Lock] = field(default_factory=dict, init=False, repr=False)

    async def handle(self, context: Any) -> InvokeResponse:
        """Decode the invoke on ``context`` and return the ``InvokeResponse`` (card 200, or error 400)."""
        activity = context.activity
        if getattr(activity, "name", None) != INVOKE_NAME:
            return _error_response(f"unsupported invoke: {getattr(activity, 'name', None)}")
        value = activity.value if isinstance(activity.value, Mapping) else getattr(activity.value, "model_dump", lambda **k: {})(mode="json")
        action = value.get("action") if isinstance(value, Mapping) else None
        if not isinstance(action, Mapping):
            return _error_response("missing action")
        verb, data = action.get("verb"), action.get("data")
        approval_id = data.get("approval_id") if isinstance(data, Mapping) else None
        if verb not in (*VERBS, "refresh"):
            return _error_response(f"unknown verb: {verb}")
        if not isinstance(approval_id, str) or not approval_id:
            return _error_response("missing approval_id")
        lock = self._locks.setdefault(approval_id, asyncio.Lock())
        async with lock:
            done = self._resolved.get(approval_id)
            if done is not None:
                return _card_response(done)
            if verb == "refresh":
                return _error_response(f"approval {approval_id} is still pending")
            actor = getattr(getattr(activity, "from_property", None), "name", None) or \
                getattr(getattr(activity, "from_property", None), "id", None) or "unknown"
            try:
                if _takes_inputs(self.decide):
                    inputs = {k: v for k, v in data.items() if k != "approval_id"} if verb == "approve" else {}
                    info = self.decide(approval_id, verb == "approve", actor, inputs)
                else:
                    info = self.decide(approval_id, verb == "approve", actor)
                if asyncio.iscoroutine(info) or isinstance(info, asyncio.Future):
                    info = await info
            except ApprovalInputError as e:
                return _card_response(e.card) if e.card is not None else _error_response(str(e))
            if info is None:
                return _error_response(f"unknown approval id: {approval_id}")
            card = resolved_card(info.title, info.summary, info.details, approved=verb == "approve",
                                 by=actor, when=self.clock(), edited=info.edited)
            self._resolved[approval_id] = card
            return _card_response(card)

    def register(self, app: Any) -> None:
        """Route ``adaptiveCard/action`` invokes on an ``AgentApplication`` here and send the invokeResponse.

        Uses ``app.invoke(name)`` when present, else (hosting-core 1.7) ``app.add_route(selector, handler,
        is_invoke=True)`` with a selector matching invoke activities of that name."""
        async def _on_card_action(context, state):  # noqa: ANN001
            await context.send_activity(Activity(type=ActivityTypes.invoke_response, value=await self.handle(context)))

        if hasattr(app, "invoke"):
            app.invoke(INVOKE_NAME)(_on_card_action)
            return

        def _selector(context) -> bool:  # noqa: ANN001
            activity = context.activity
            return getattr(activity, "type", None) == ActivityTypes.invoke and getattr(activity, "name", None) == INVOKE_NAME

        app.add_route(_selector, _on_card_action, is_invoke=True)
