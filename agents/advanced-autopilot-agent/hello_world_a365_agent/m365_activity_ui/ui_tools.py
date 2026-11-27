"""Components as tools: the MODEL renders cards by calling function tools, so cards appear on real data.

``UiToolkit`` owns the tool definitions (Responses API ``function`` tools) and the approval state; ``toolkit.turn(
presenter)`` returns a per-turn ``UiTurn`` that records tool outputs (grounding), dispatches UI tool calls and
queues cards on the presenter (sent with the final message only; email turns get email HTML blocks instead).

Caller loop::

    toolkit = UiToolkit(send=send_email)                 # send(proposal) -> awaited only on Approve
    toolkit.register(app)                                # approval clicks (or ApprovalDesk via toolkit.desk)
    ui = toolkit.turn(presenter)
    await present_responses(presenter, events, ui=ui)    # records function_call_output / mcp_call outputs
    ...
    result = await ui.call(name, arguments)              # for names in toolkit.names; returns the tool result text
    ui.record_output(my_tool_output_text)                # for outputs the stream does not carry
"""
from __future__ import annotations

import html
import json
import logging
import re
import uuid
from typing import Any, Awaitable, Callable, Mapping

from .approval import ApprovalDesk, ApprovalInputError, CardInfo, approval_card
from .cards import kpi_strip
from .charts import bar_chart, donut_chart, gauge_chart, horizontal_bar_chart, line_chart, pie_chart
from .citations import citations as make_citations
from .email import EmailBlock, approval_block, bar_table, figures_table, sources_footnotes
from .forms import FormDesk
from .people import people_card
from .presenter import TurnPresenter
from .tables import require_https, table_card

log = logging.getLogger(__name__)
CHART_TYPES = ("bar", "hbar", "line", "pie", "donut", "gauge")
OnFormSubmit = Callable[[str, Mapping[str, Any], str], Any]

LABELS = {
    "show_chart": "Drawing a chart...",
    "show_figures": "Preparing key figures...",
    "show_table": "Building a table...",
    "show_people": "Listing people...",
    "show_form": "Preparing a form...",
    "show_sources": "Listing sources...",
    "clear_components": "Updating the answer...",
    "propose_email": "Drafting an email for your approval...",
}
_NUM = re.compile(r"-?\d[\d,]*(?:\.\d+)?|-?\.\d+")
_NUMERIC_CELL = re.compile(r"^[\s$€£]*-?\d[\d,]*(?:\.\d+)?\s*(?:[kKmMbB]|%)?\s*$")
_EMAIL_IN_TEXT = re.compile(r"[^\s@<>()\[\]\"',;:]+@[^\s@<>()\[\]\"',;:]+")
_SCALE = {"k": 1e3, "m": 1e6, "b": 1e9}


def _numbers(text: str) -> set[float]:
    out: set[float] = set()
    for tok in _NUM.findall(text):
        try:
            out.add(float(tok.replace(",", "")))
        except ValueError:
            pass
    return out


def _value_forms(value: Any) -> tuple[str, set[float]]:
    """(literal text, candidate numbers) for a chart/figure value: ``1,200`` / ``$1.2M`` / ``12%`` / 42."""
    if isinstance(value, bool):
        raise ValueError("boolean is not a value")
    s = str(value).strip()
    nums = _numbers(s)
    if not nums:
        raise ValueError("no number")
    cand = set(nums)
    m = re.search(r"(-?\d[\d,]*(?:\.\d+)?)\s*([kKmMbB])\b", s)
    if m:
        cand.add(float(m.group(1).replace(",", "")) * _SCALE[m.group(2).lower()])
    return s, cand


def _to_float(value: Any) -> float:
    """Number for drawing: ``1,200`` -> 1200, ``$1.2M`` -> 1.2e6, ``12%`` -> 12."""
    s, cand = _value_forms(value)
    first = float(_NUM.search(s).group().replace(",", ""))  # type: ignore[union-attr]
    return max((c for c in cand if c != first), default=first) if re.search(r"\d\s*[kKmMbB]\b", s) else first


def _fn(name: str, description: str, properties: dict, required: list[str]) -> dict[str, Any]:
    return {"type": "function", "name": name, "description": description, "strict": False,
            "parameters": {"type": "object", "properties": properties, "required": required}}


_ITEM = {"type": "object", "properties": {"label": {"type": "string"}, "value": {"type": ["number", "string"]}},
         "required": ["label", "value"]}

UI_INSTRUCTIONS = """\
You can attach visual components to your final answer with show_chart (bar, hbar, line, pie, donut, gauge), \
show_figures, show_table, show_people, show_form, show_sources and propose_email.
First gather all the data you need with the other tools. Only when you are ready to answer, call the component tools
(once per component, using numbers and email addresses that appeared in tool results), then write your final answer
immediately after. Components are shown BELOW your text, so refer to them only as "below" or "here".
When a component carries the numbers, write one short sentence and do not repeat the component's values or draw
charts or tables in text. A component call does not end the turn. To change one, call it again with the same id; to
remove one, call clear_components. propose_email only drafts: never say an email was sent. Its body must say what
the USER asked to be said (e.g. asked to "ask how they're doing" -> the email asks how they are); write it from the
user to the recipient, never as a reply that answers the original email. show_form collects input from the user:
the answer arrives later as a new message, so do not assume values."""

_ID = {"id": {"type": "string", "description": "Optional. Reusing an id replaces that component."}}


def _with_id(props: dict) -> dict:
    return {**props, **_ID}


TOOL_DEFINITIONS: list[dict[str, Any]] = [
    _fn("show_chart", "Show a chart card: type bar, hbar (horizontal bar), line, pie, donut, or gauge. bar/hbar/line/"
        "pie/donut take series [{label, value}]; gauge takes value (+ optional target, min, max). Every value must "
        "come from tool results you already received this turn; do not invent or estimate numbers.",
        _with_id({"title": {"type": "string"}, "type": {"type": "string", "enum": list(CHART_TYPES)},
         "series": {"type": "array", "items": _ITEM}, "value": {"type": ["number", "string"]},
         "target": {"type": "number"}, "min": {"type": "number"}, "max": {"type": "number"}}), ["title", "type"]),
    _fn("show_table", "Show a table card. Numeric cells must come from tool results received this turn. Optional "
        "links: one https URL (or null) per row.",
        _with_id({"title": {"type": "string"}, "columns": {"type": "array", "items": {"type": "string"}},
         "rows": {"type": "array", "items": {"type": "array", "items": {"type": ["number", "string", "null"]}}},
         "links": {"type": "array", "items": {"type": ["string", "null"]}}}), ["columns", "rows"]),
    _fn("show_people", "Show a card listing people. Email addresses must appear in tool results received this turn.",
        _with_id({"title": {"type": "string"}, "people": {"type": "array", "items": {"type": "object", "properties": {
            "name": {"type": "string"}, "email": {"type": "string"}, "role": {"type": "string"}},
            "required": ["name"]}}}), ["people"]),
    _fn("show_form", "Show an input form to the user. Their submission arrives later as a new message. Field kinds: "
        "text, number, date, time, toggle, choice, multichoice (choices: list of strings).",
        _with_id({"title": {"type": "string"}, "submit_label": {"type": "string"},
         "fields": {"type": "array", "items": {"type": "object", "properties": {
             "id": {"type": "string"}, "label": {"type": "string"}, "kind": {"type": "string"},
             "required": {"type": "boolean"}, "choices": {"type": "array", "items": {"type": "string"}}},
             "required": ["id"]}}}), ["title", "fields"]),
    _fn("show_figures", "Show a row of key figures (KPI tiles). Values must come from tool results received this turn.",
        _with_id({"title": {"type": "string"}, "items": {"type": "array", "items": {
            "type": "object", "properties": {"label": {"type": "string"}, "value": {"type": ["number", "string"]},
                                             "delta": {"type": "string"}}, "required": ["label", "value"]}}}),
        ["title", "items"]),
    _fn("show_sources", "Show the sources behind the answer as citations.",
        _with_id({"items": {"type": "array", "items": {"type": "object", "properties": {
            "title": {"type": "string"}, "url": {"type": "string"}, "snippet": {"type": "string"}},
            "required": ["title"]}}}), ["items"]),
    _fn("propose_email", "Propose an email for the user to approve. It is NOT sent until the user presses Approve; "
        "never say it was sent.",
        _with_id({"to": {"type": "array", "items": {"type": "string"}}, "subject": {"type": "string"},
         "body": {"type": "string"}, "cc": {"type": "array", "items": {"type": "string"}}}),
        ["to", "subject", "body"]),
    _fn("clear_components", "Remove a queued component by id, or all queued components when id is omitted.",
        {"id": {"type": "string"}}, []),
]

MAX_SUBJECT, MAX_BODY = 200, 5000   # caps on an approver's edited subject/body (card stays well under client size limits)

Send = Callable[[Mapping[str, Any]], Awaitable[Any]]


class UiToolkit:
    """Tool definitions plus approval state. ``send(proposal)`` is the caller's async sender, awaited once per
    approved proposal (never on Reject, never on replay). ``grounding="off"`` skips the numeric grounding check.
    ``on_form_submit(form_id, values, actor)`` (sync or async) enables ``show_form``: it runs once per submitted form
    (FormDesk hook); use it to start a new agent turn with the values. Without it ``show_form`` is not offered."""

    names = tuple(t["name"] for t in TOOL_DEFINITIONS)

    def __init__(self, send: Send | None = None, *, grounding: str = "on", email_approval_mode: str = "reply",
                 on_form_submit: OnFormSubmit | None = None) -> None:
        if grounding not in ("on", "off"):
            raise ValueError("grounding must be 'on' or 'off'")
        self.send, self.grounding, self.email_approval_mode = send, grounding, email_approval_mode
        self.labels = dict(LABELS)
        self.decided: set[str] = set()
        self.proposals: dict[str, dict[str, Any]] = {}
        self.desk = ApprovalDesk(self.decide)
        self.on_form_submit = on_form_submit
        self.forms = FormDesk(self._form_submitted)

    async def _form_submitted(self, form_id: str, values: Mapping[str, Any], actor: str) -> None:
        if self.on_form_submit is not None:
            res = self.on_form_submit(form_id, values, actor)
            if hasattr(res, "__await__"):
                await res

    @property
    def tools(self) -> list[dict[str, Any]]:
        """Responses API ``tools=`` entries (append to the caller's own tools)."""
        return [json.loads(json.dumps(t)) for t in TOOL_DEFINITIONS
                if t["name"] != "show_form" or self.on_form_submit is not None]

    def register(self, app: Any) -> None:
        self.desk.register(app)
        if self.on_form_submit is not None:
            self.forms.register(app)

    def pending_card(self, prop: Mapping[str, Any], error: str | None = None, *, subject: Any = None, body: Any = None) -> dict[str, Any]:
        """The editable approval card for a proposal: To (and Cc) read-only, Subject and Body prefilled inputs."""
        details = {"To": ", ".join(prop["to"]), **({"Cc": ", ".join(prop["cc"])} if prop.get("cc") else {})}
        subj = prop["subject"] if subject is None else str(subject)
        return approval_card(
            prop["id"], f"Send email: {prop['subject']}", "Awaiting your approval. Not sent yet. Edit the subject or body if you like.",
            details, error=error,
            editable=[{"id": "subject", "label": "Subject", "value": subj, "max_length": MAX_SUBJECT},
                      {"id": "body", "label": "Body", "value": prop["body"] if body is None else str(body),
                       "multiline": True, "max_length": MAX_BODY}])

    async def decide(self, approval_id: str, approved: bool, actor: str,
                     inputs: Mapping[str, Any] | None = None) -> CardInfo | None:
        """ApprovalDesk callback; also call it for an email-channel ``APPROVE <id>`` reply (then guard replays
        yourself with ``approval_id in toolkit.decided``). ``inputs`` are the card's edited ``subject`` / ``body``
        (Approve only): validated (non-empty, length caps) and the sent proposal updated; any other key, notably
        recipients, is ignored. Invalid edits raise ``ApprovalInputError`` carrying the card with an error line."""
        prop = self.proposals.get(approval_id)
        if prop is None:
            return None
        edited = False
        if approved and inputs and approval_id not in self.decided:
            subject = str(inputs["subject"]).strip() if inputs.get("subject") is not None else prop["subject"]
            body = str(inputs["body"]).strip() if inputs.get("body") is not None else prop["body"]
            err = ("Subject must not be empty." if not subject else "Body must not be empty." if not body else
                   f"Subject is over {MAX_SUBJECT} characters." if len(subject) > MAX_SUBJECT else
                   f"Body is over {MAX_BODY} characters." if len(body) > MAX_BODY else None)
            if err:
                raise ApprovalInputError(err, self.pending_card(prop, err, subject=inputs.get("subject"), body=inputs.get("body")))
            edited = (subject, body) != (prop["subject"], prop["body"])
            prop["subject"], prop["body"], prop["edited"] = subject, body, edited
        edited = edited or bool(prop.get("edited") and approved)
        if approved and self.send is not None and approval_id not in self.decided:
            self.decided.add(approval_id)
            await self.send(prop)
        self.decided.add(approval_id)
        return CardInfo(f"Email: {prop['subject']}", f"To: {', '.join(prop['to'])}", {"Body": prop["body"]}, edited=edited)

    def turn(self, presenter: TurnPresenter) -> "UiTurn":
        return UiTurn(self, presenter)


class UiTurn:
    """Per-turn state: tool outputs seen (grounding) and the cards queued on the presenter."""

    def __init__(self, toolkit: UiToolkit, presenter: TurnPresenter) -> None:
        self.kit, self.p = toolkit, presenter
        self.labels = toolkit.labels
        self._outputs: list[str] = []
        self._numbers: set[float] = set()
        self._text = ""
        self._queue: dict[str, Callable[[], None]] = {}  # id -> renderer; flushed onto the presenter at finish
        self._last_cid = ""
        self._email_ids: dict[str, str] = {}  # component id -> proposal id
        presenter.before_finish(self._flush)

    def _flush(self) -> None:
        for render in self._queue.values():
            render()
        self._queue.clear()

    def _enqueue(self, cid: str, render: Callable[[], None]) -> str:
        replaced = cid in self._queue
        self._queue[cid] = render  # last write wins, keeps first position
        return ("queued (replaced the earlier one)" if replaced else "queued") + \
            "; it will appear with your final answer. Continue; write the answer when ready."

    def record_output(self, output: Any) -> None:
        text = output if isinstance(output, str) else json.dumps(output, default=str)
        self._outputs.append(text)
        self._text += "\n" + text
        self._numbers |= _numbers(text)

    def observe(self, item: Any) -> None:
        """Adapter hook for a finished output item: ``function_call_output`` / ``mcp_call`` outputs are recorded."""
        g = (lambda k: item.get(k) if isinstance(item, Mapping) else getattr(item, k, None))
        if g("type") in ("function_call_output", "mcp_call", "web_search_call", "file_search_call") and g("output") is not None:
            out = g("output")
            if isinstance(out, str) and out.startswith(("queued", "cleared", "Error:")):
                return  # our own tool results (they can echo refused values) are not evidence
            self.record_output(out)

    def _grounded(self, value: Any) -> bool:
        literal, cand = _value_forms(value)
        if literal in self._text:
            return True
        return any(abs(c - n) <= 1e-9 * max(1.0, abs(c)) for c in cand for n in self._numbers)

    def _check(self, rows: list[Mapping[str, Any]]) -> str | None:
        if self.kit.grounding == "off":
            return None
        for r in rows:
            try:
                ok = self._grounded(r["value"])
            except ValueError:
                return f"Error: value {r.get('value')!r} for {r.get('label')!r} is not a number."
            if not ok:
                return (f"Error: value {r['value']!r} for {r.get('label')!r} does not appear in any tool output "
                        "this turn. Use only numbers from tool results (or call the data tool first); nothing was rendered.")
        return None

    async def call(self, name: str, arguments: Any) -> str:
        """Run a UI tool; returns the short tool result for the model (``queued...`` or an ``Error: ...``).
        Logs one INFO line per call: name, id, accepted|refused, reason."""
        self._last_cid = ""
        result = await self._call(name, arguments)
        refused = result.startswith("Error:")
        cid = self._last_cid or (arguments.get("id") if isinstance(arguments, Mapping) else "") or "-"
        log.info("ui_tool name=%s id=%s %s reason=%s", name, cid, "refused" if refused else "accepted",
                 result[:300] if refused else "ok")
        return result

    async def _call(self, name: str, arguments: Any) -> str:
        if isinstance(arguments, str):
            try:
                arguments = json.loads(arguments or "{}")
            except ValueError:
                return "Error: arguments are not valid JSON."
        if not isinstance(arguments, Mapping):
            return "Error: arguments must be an object."
        if name == "clear_components":
            cid = arguments.get("id")
            for k in ([cid] if cid else list(self._queue)):
                self._queue.pop(k, None)
                self._drop_proposal(k)
            return "cleared"
        fn = getattr(self, f"_{name}", None) if name in UiToolkit.names else None
        if fn is None:
            return f"Error: unknown UI tool {name!r}."
        try:
            return fn(arguments)
        except (KeyError, TypeError, ValueError) as e:
            return f"Error: invalid arguments ({type(e).__name__}: {e}). Fix them and call {name} again."

    def _drop_proposal(self, cid: str) -> None:
        pid = self._email_ids.pop(cid, None)
        if pid and pid not in self.kit.decided:
            self.kit.proposals.pop(pid, None)

    def _cid(self, a: Mapping[str, Any], kind: str, title: Any = "") -> str:
        self._last_cid = str(a.get("id") or f"{kind}:{title}")
        return self._last_cid

    def _rows(self, a: Mapping[str, Any], key: str) -> list[Mapping[str, Any]]:
        rows = a[key]
        if not isinstance(rows, list) or not rows or not all(isinstance(r, Mapping) and "label" in r and "value" in r for r in rows):
            raise ValueError(f"{key} must be a non-empty list of {{label, value}}")
        return rows

    def _show_chart(self, a: Mapping[str, Any]) -> str:
        title, kind = str(a["title"]), a.get("type") or a.get("kind") or "bar"
        if kind not in CHART_TYPES:
            return f"Error: type must be one of {', '.join(CHART_TYPES)}."
        cid = self._cid(a, "chart", title)
        if kind == "gauge":
            if "value" not in a:
                return "Error: gauge needs value."
            if err := self._check([{"label": title, "value": a["value"]}]):
                return err
            value = _to_float(a["value"])
            target = float(a["target"]) if a.get("target") is not None else None
            lo = float(a.get("min", 0))
            hi = float(a["max"]) if a.get("max") is not None else max(100.0, value, target or 0.0)

            def render_gauge() -> None:
                if self.p.surface == "email":
                    self.p.add_email_block(figures_table([{"label": title, "value": a["value"]}]))
                else:
                    self.p.add_card(gauge_chart(title, value, target=target, min_value=lo, max_value=hi))
            return self._enqueue(cid, render_gauge)
        rows = self._rows(a, "series")
        if err := self._check(rows):
            return err
        series = [{"label": str(r["label"]), "value": _to_float(r["value"])} for r in rows]
        builders = {"bar": bar_chart, "hbar": horizontal_bar_chart, "line": line_chart, "pie": pie_chart,
                    "donut": donut_chart}

        def render() -> None:
            if self.p.surface == "email":
                self.p.add_email_block(bar_table(title, series))
            else:
                self.p.add_card(builders[kind](title, series))
        return self._enqueue(cid, render)

    def _show_table(self, a: Mapping[str, Any]) -> str:
        cols, rows, links = a["columns"], a["rows"], a.get("links")
        if not isinstance(cols, list) or not cols or not all(isinstance(c, str) for c in cols):
            raise ValueError("columns must be a non-empty list of strings")
        if not isinstance(rows, list) or not rows or not all(isinstance(r, list) and len(r) == len(cols) for r in rows):
            raise ValueError("rows must be a non-empty list of lists, each as long as columns")
        if links is not None and (not isinstance(links, list) or len(links) != len(rows)):
            raise ValueError("links must have one entry (url or null) per row")
        for ln in links or []:
            if ln:
                require_https(ln)
        if self.kit.grounding != "off":
            for r in rows:
                for cell in r:
                    if isinstance(cell, bool) or cell is None:
                        continue
                    if isinstance(cell, (int, float)) or (isinstance(cell, str) and _NUMERIC_CELL.match(cell)):
                        if not self._grounded(cell):
                            return (f"Error: table value {cell!r} does not appear in any tool output this turn. "
                                    "Use only numbers from tool results; nothing was rendered.")
        title = str(a.get("title") or "") or None
        data = [["" if c is None else c for c in r] for r in rows]

        def render() -> None:
            if self.p.surface == "email":
                head = "".join(f"<th>{html.escape(c)}</th>" for c in cols)
                body = "".join("<tr>" + "".join(f"<td>{html.escape(str(c))}</td>" for c in r) + "</tr>" for r in data)
                cap = f"<p><b>{html.escape(title)}</b></p>" if title else ""
                text = "\n".join(" | ".join(str(c) for c in r) for r in [cols, *data])
                self.p.add_email_block(EmailBlock(f"{cap}<table border='1' cellpadding='4'><tr>{head}</tr>{body}</table>", text))
            else:
                self.p.add_card(table_card(title, cols, data, links=links))
        return self._enqueue(self._cid(a, "table", title or ""), render)

    def _show_people(self, a: Mapping[str, Any]) -> str:
        people = a["people"]
        if not isinstance(people, list) or not people or not all(isinstance(x, Mapping) and x.get("name") for x in people):
            raise ValueError("people must be a non-empty list of {name, email?, role?}")
        if self.kit.grounding != "off":
            seen = self._text.lower()
            for x in people:
                em = str(x.get("email") or "").strip().lower()
                if em and em not in seen:
                    return (f"Error: email {em!r} does not appear in any tool output this turn. "
                            "Use only addresses from tool results; nothing was rendered.")
        title = str(a.get("title") or "People")
        ppl = [{k: x[k] for k in ("name", "email", "role") if x.get(k)} for x in people]

        def render() -> None:
            if self.p.surface == "email":
                items = "".join(f"<li>{html.escape(x['name'])}" + (f" &lt;{html.escape(x['email'])}&gt;" if x.get("email") else "")
                                + (f" - {html.escape(x['role'])}" if x.get("role") else "") + "</li>" for x in ppl)
                self.p.add_email_block(EmailBlock(f"<p><b>{html.escape(title)}</b></p><ul>{items}</ul>",
                                                  "\n".join(x["name"] for x in ppl)))
            else:
                card = people_card(title, ppl)
                if card is not None:
                    self.p.add_card(card)
        return self._enqueue(self._cid(a, "people", title), render)

    def _show_form(self, a: Mapping[str, Any]) -> str:
        if self.kit.on_form_submit is None:
            return "Error: forms are not enabled for this agent."
        if self.p.surface == "email":
            return "Error: forms are not available on email; ask the user in text instead."
        fields = a["fields"]
        if not isinstance(fields, list) or not fields or not all(isinstance(f, Mapping) and f.get("id") for f in fields):
            raise ValueError("fields must be a non-empty list of {id, label?, kind?, required?, choices?}")
        title, label = str(a["title"]), str(a.get("submit_label") or "Submit")
        form_id = uuid.uuid4().hex[:12]
        self.kit.forms.form(form_id, title, fields, label)  # validates kinds now; raises ValueError -> Error result

        def render() -> None:
            self.p.add_card(self.kit.forms.form(form_id, title, fields, label))
        return self._enqueue(self._cid(a, "form", title), render).replace(
            "queued", "queued; the user's answers will arrive later as a new message", 1)

    def _show_figures(self, a: Mapping[str, Any]) -> str:
        items = self._rows(a, "items")
        if err := self._check(items):
            return err
        figs = [{"label": str(i["label"]), "value": i["value"], **({"delta": str(i["delta"])} if i.get("delta") else {})}
                for i in items]
        title = str(a.get("title") or "") or None
        def render() -> None:
            if self.p.surface == "email":
                self.p.add_email_block(figures_table(figs, title=title))
            else:
                self.p.add_card(kpi_strip(figs, title=title))
        return self._enqueue(self._cid(a, "figures", title), render)

    def _show_sources(self, a: Mapping[str, Any]) -> str:
        items = a["items"]
        if not isinstance(items, list) or not items or not all(isinstance(i, Mapping) and i.get("title") for i in items):
            raise ValueError("items must be a non-empty list of {title, url?, snippet?}")
        cites = make_citations([{"title": i["title"], "url": i.get("url"), "content": i.get("snippet")} for i in items])

        def render() -> None:
            if self.p.surface == "email":
                self.p.add_email_block(sources_footnotes(items))
            else:
                self.p.add_citations(cites)
        return self._enqueue(self._cid(a, "sources"), render)

    def _propose_email(self, a: Mapping[str, Any]) -> str:
        to, subject, body = a["to"], str(a["subject"]), str(a["body"])
        cc = a.get("cc") or []
        if not isinstance(to, list) or not to or not all(isinstance(x, str) and "@" in x for x in to):
            return "Error: 'to' must be a non-empty list of email addresses."
        if not isinstance(cc, list) or not all(isinstance(x, str) and "@" in x for x in cc):
            return "Error: 'cc' must be a list of email addresses."
        if not subject.strip() or not body.strip():
            return "Error: subject and body must not be empty."
        cid = self._cid(a, "email", subject)
        self._drop_proposal(cid)
        aid = uuid.uuid4().hex[:12]
        self._email_ids[cid] = aid
        self.kit.proposals[aid] = {"id": aid, "to": to, "cc": cc, "subject": subject, "body": body}
        prop = self.kit.proposals[aid]
        details = {"To": ", ".join(to), **({"Cc": ", ".join(cc)} if cc else {}), "Body": body[:500]}
        def render() -> None:
            if self.p.surface == "email":
                self.p.add_email_block(approval_block(aid, f"Send email: {subject}", "Awaiting your approval.", details,
                                                      mode=self.kit.email_approval_mode))
            else:
                self.p.add_card(self.kit.pending_card(prop))
        return self._enqueue(cid, render).replace("queued", "queued as a draft; the email has NOT been sent", 1)
