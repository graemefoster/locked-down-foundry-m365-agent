"""Input-form Adaptive Cards that submit via ``Action.Execute`` and refresh in place (Universal Actions).

Same delivery model as ``approval.py``: a click on the submit button arrives as an ``adaptiveCard/action``
invoke; ``activity.value["action"]`` is ``{"verb": <verb>, "data": {"form_id": ..., <input id>: <value>, ...}}``
(Teams merges every ``Input.*`` value into ``data`` keyed by the input ``id``). The reply is an
``InvokeResponse`` whose body carries the replacement card.

``FormDesk`` keeps the declared fields per form id, validates the submitted values, calls
``on_submit(form_id, values, actor)`` once, and replaces the card with a read-only "Submitted by X" summary.
Invalid input re-renders the form (values kept) with an error TextBlock; the handler is not called::

    desk = FormDesk(on_submit)                    # async or sync: on_submit(form_id, values, actor)
    desk.register(app)
    card = desk.form("m1", "Schedule meeting", [
        {"id": "subject", "kind": "text", "label": "Subject", "required": True},
        {"id": "date", "kind": "date", "label": "Date", "required": True},
        {"id": "time", "kind": "time", "label": "Time"},
        {"id": "who", "kind": "choice", "label": "Attendees", "choices": ["Ana", "Sam"], "required": True},
    ], submit_label="Schedule")
    await context.send_activity(Activity(type="message", attachments=[card_attachment(card)]))

Checks run server-side because clients only enforce ``isRequired`` loosely: required, choice membership
(choice and multichoice), ``YYYY-MM-DD`` dates, ``HH:MM`` times, numbers. Form state is in memory (one process).
Rendering of inputs in a live Teams client is unverified here; shapes follow the Adaptive Card 1.5 schema.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from datetime import date, datetime, time
from typing import Any, Awaitable, Callable, Mapping, Sequence

from microsoft_agents.activity import Activity, ActivityTypes, InvokeResponse

from .approval import INVOKE_NAME, _card_response, _error_response
from .cards import adaptive_card

KINDS = ("text", "date", "time", "choice", "multichoice", "toggle", "number")
DEFAULT_VERB = "submit_form"

OnSubmit = Callable[[str, dict[str, Any], str], "Any | Awaitable[Any]"]


def _choices(field_: Mapping[str, Any]) -> list[dict[str, str]]:
    out = []
    for c in field_.get("choices") or []:
        if isinstance(c, Mapping):
            out.append({"title": str(c.get("title", c.get("value"))), "value": str(c.get("value", c.get("title")))})
        else:
            out.append({"title": str(c), "value": str(c)})
    return out


def _input(f: Mapping[str, Any]) -> dict[str, Any]:
    kind = f.get("kind", "text")
    if kind not in KINDS:
        raise ValueError(f"unknown field kind: {kind}")
    base: dict[str, Any] = {"id": f["id"], "label": f.get("label", f["id"])}
    if f.get("required"):
        base["isRequired"] = True
        base["errorMessage"] = f"{base['label']} is required"
    value = f.get("value")
    if kind in ("text", "date", "time"):
        base["type"] = {"text": "Input.Text", "date": "Input.Date", "time": "Input.Time"}[kind]
    elif kind == "number":
        base["type"] = "Input.Number"
    elif kind == "toggle":
        base.update(type="Input.Toggle", title=base.pop("label"), valueOn="true", valueOff="false")
        value = "true" if value in (True, "true") else "false"
    else:
        base.update(type="Input.ChoiceSet", choices=_choices(f), style="compact" if kind == "choice" else "expanded",
                    isMultiSelect=kind == "multichoice")
        if isinstance(value, (list, tuple)):
            value = ",".join(str(v) for v in value)
    if value is not None and value != "":
        if kind == "number":
            try:
                num = float(value)
                base["value"] = int(num) if num.is_integer() else num
            except (TypeError, ValueError):
                pass  # unparseable echo: leave the input empty
        else:
            base["value"] = str(value)
    return base


def form_card(title: str, fields: Sequence[Mapping[str, Any]], submit_label: str = "Submit",
              verb: str = DEFAULT_VERB, form_id: str = "", error: str | None = None) -> dict[str, Any]:
    """Pending form: title, optional red error line, one ``Input.*`` per field and a submit ``Action.Execute``
    (``verb``, data ``{form_id}``; client adds the input values keyed by field id)."""
    body: list[dict[str, Any]] = [{"type": "TextBlock", "text": title, "weight": "Bolder", "size": "Medium", "wrap": True}]
    if error:
        body.append({"type": "TextBlock", "text": error, "color": "Attention", "wrap": True})
    body.extend(_input(f) for f in fields)
    card = adaptive_card(body)
    card["actions"] = [{"type": "Action.Execute", "title": submit_label, "verb": verb,
                        "data": {"form_id": form_id}, "style": "positive"}]
    return card


def submitted_card(title: str, fields: Sequence[Mapping[str, Any]], values: Mapping[str, Any], *, by: str) -> dict[str, Any]:
    """Read-only summary: the submitted values as facts, no actions, "Submitted by X"."""
    facts = [{"title": str(f.get("label", f["id"])), "value": _show(values.get(f["id"]))} for f in fields]
    return adaptive_card([
        {"type": "TextBlock", "text": title, "weight": "Bolder", "size": "Medium", "wrap": True},
        {"type": "FactSet", "facts": facts},
        {"type": "TextBlock", "text": f"Submitted by {by}", "weight": "Bolder", "color": "Good", "wrap": True},
    ])


def _show(v: Any) -> str:
    if v is None or v == "" or v == []:
        return "-"
    if isinstance(v, bool):
        return "Yes" if v else "No"
    if isinstance(v, list):
        return ", ".join(str(x) for x in v)
    return str(v)


def validate(fields: Sequence[Mapping[str, Any]], raw: Mapping[str, Any]) -> tuple[dict[str, Any], list[str]]:
    """Return ``(clean values, error messages)`` for submitted ``raw`` data against the declared fields."""
    values: dict[str, Any] = {}
    errors: list[str] = []
    for f in fields:
        fid, kind, label = f["id"], f.get("kind", "text"), f.get("label", f["id"])
        v = raw.get(fid)
        if kind == "toggle":
            values[fid] = str(v).lower() in ("true", "1", "yes", "on") if v is not None else False
            if f.get("required") and not values[fid]:
                errors.append(f"{label} is required")
            continue
        if isinstance(v, str):
            v = v.strip()
        if v is None or v == "" or v == []:
            values[fid] = [] if kind == "multichoice" else None
            if f.get("required"):
                errors.append(f"{label} is required")
            continue
        try:
            if kind == "date":
                date.fromisoformat(str(v))
                values[fid] = str(v)
            elif kind == "time":
                time.fromisoformat(str(v))
                values[fid] = str(v)
            elif kind == "number":
                values[fid] = float(v) if not isinstance(v, (int, float)) or isinstance(v, bool) else v
                if isinstance(values[fid], float) and values[fid].is_integer():
                    values[fid] = int(values[fid])
            elif kind in ("choice", "multichoice"):
                allowed = {c["value"] for c in _choices(f)}
                picked = [p.strip() for p in v.split(",")] if isinstance(v, str) else [str(p) for p in v]
                if kind == "choice" and len(picked) != 1:
                    raise ValueError
                bad = [p for p in picked if p not in allowed]
                if bad:
                    errors.append(f"{label}: invalid choice {', '.join(bad)}")
                    continue
                values[fid] = picked[0] if kind == "choice" else picked
            else:
                values[fid] = str(v)
        except (ValueError, TypeError):
            fmt = {"date": "YYYY-MM-DD", "time": "HH:MM", "number": "a number"}.get(kind, "a valid value")
            errors.append(f"{label} must be {fmt}")
    return values, errors


@dataclass
class _Form:
    title: str
    fields: list[dict[str, Any]]
    submit_label: str
    done: dict[str, Any] | None = None
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)


@dataclass
class FormDesk:
    """Handles ``adaptiveCard/action`` invokes for one form verb.

    ``on_submit(form_id, values, actor)`` (sync or async) runs at most once per form id: the first valid submit
    wins and later clicks get the submitted card back without calling it. If it raises, the form stays open.
    """
    on_submit: OnSubmit
    verb: str = DEFAULT_VERB
    _forms: dict[str, _Form] = field(default_factory=dict, init=False, repr=False)

    def form(self, form_id: str, title: str, fields: Sequence[Mapping[str, Any]], submit_label: str = "Submit") -> dict[str, Any]:
        """Declare a form and return its pending card (fields are remembered for validation)."""
        fs = [dict(f) for f in fields]
        for f in fs:
            _input(f)  # reject unknown kinds up front
        self._forms[form_id] = _Form(title, fs, submit_label)
        return form_card(title, fs, submit_label, self.verb, form_id)

    async def handle(self, context: Any) -> InvokeResponse:
        """Decode the invoke on ``context``; return the refreshed/error-bearing card (200) or a 400 error."""
        activity = context.activity
        if getattr(activity, "name", None) != INVOKE_NAME:
            return _error_response(f"unsupported invoke: {getattr(activity, 'name', None)}")
        value = activity.value if isinstance(activity.value, Mapping) else getattr(activity.value, "model_dump", lambda **k: {})(mode="json")
        action = value.get("action") if isinstance(value, Mapping) else None
        if not isinstance(action, Mapping):
            return _error_response("missing action")
        data = action.get("data")
        if action.get("verb") != self.verb:
            return _error_response(f"unknown verb: {action.get('verb')}")
        form_id = data.get("form_id") if isinstance(data, Mapping) else None
        if not isinstance(form_id, str) or not form_id:
            return _error_response("missing form_id")
        form = self._forms.get(form_id)
        if form is None:
            return _error_response(f"unknown form id: {form_id}")
        async with form.lock:
            if form.done is not None:
                return _card_response(form.done)
            values, errors = validate(form.fields, data)
            if errors:
                shown = [{**f, "value": data.get(f["id"], f.get("value"))} for f in form.fields]
                return _card_response(form_card(form.title, shown, form.submit_label, self.verb, form_id, "; ".join(errors)))
            fp = getattr(activity, "from_property", None)
            actor = getattr(fp, "name", None) or getattr(fp, "id", None) or "unknown"
            res = self.on_submit(form_id, values, actor)
            if asyncio.iscoroutine(res) or isinstance(res, asyncio.Future):
                await res
            form.done = submitted_card(form.title, form.fields, values, by=actor)
            return _card_response(form.done)

    def register(self, app: Any) -> None:
        """Route ``adaptiveCard/action`` invokes on an ``AgentApplication`` here and send the invokeResponse.

        Selector matches invoke activities named ``adaptiveCard/action`` whose action verb is this desk's verb,
        so it coexists with ``ApprovalDesk`` / ``PromptDesk`` routes."""
        async def _on_submit(context, state):  # noqa: ANN001
            await context.send_activity(Activity(type=ActivityTypes.invoke_response, value=await self.handle(context)))

        def _selector(context) -> bool:  # noqa: ANN001
            a = context.activity
            if getattr(a, "type", None) != ActivityTypes.invoke or getattr(a, "name", None) != INVOKE_NAME:
                return False
            v = a.value if isinstance(a.value, Mapping) else getattr(a.value, "model_dump", lambda **k: {})(mode="json")
            act = v.get("action") if isinstance(v, Mapping) else None
            return isinstance(act, Mapping) and act.get("verb") == self.verb

        app.add_route(_selector, _on_submit, is_invoke=True)
