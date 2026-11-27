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

import json
import re
import uuid
from typing import Any, Awaitable, Callable, Mapping

from .approval import ApprovalDesk, CardInfo, approval_card
from .cards import kpi_strip
from .charts import bar_chart, donut_chart
from .citations import citations as make_citations
from .email import approval_block, bar_table, figures_table, sources_footnotes
from .presenter import TurnPresenter

LABELS = {
    "show_chart": "Drawing a chart...",
    "show_figures": "Preparing key figures...",
    "show_sources": "Listing sources...",
    "clear_components": "Updating the answer...",
    "propose_email": "Drafting an email for your approval...",
}
_NUM = re.compile(r"-?\d[\d,]*(?:\.\d+)?|-?\.\d+")
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
You can attach visual components to your final answer with show_chart, show_figures, show_sources and propose_email.
First gather all the data you need with the other tools. Only when you are ready to answer, call the component tools
(once per component, using numbers that appeared in tool results), then write your final answer immediately after.
The components are shown with your answer, so refer to them in the prose ("the chart above") instead of repeating
their numbers or drawing charts in text. A component call does not end the turn. To change one, call it again with
the same id; to remove one, call clear_components. propose_email only drafts: never say an email was sent."""

_ID = {"id": {"type": "string", "description": "Optional. Reusing an id replaces that component."}}


def _with_id(props: dict) -> dict:
    return {**props, **_ID}


TOOL_DEFINITIONS: list[dict[str, Any]] = [
    _fn("show_chart", "Show a bar or donut chart card in the reply. Every value must come from tool results you "
        "already received this turn; do not invent or estimate numbers.",
        _with_id({"title": {"type": "string"}, "kind": {"type": "string", "enum": ["bar", "donut"]},
         "series": {"type": "array", "items": _ITEM}}), ["title", "kind", "series"]),
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

Send = Callable[[Mapping[str, Any]], Awaitable[Any]]


class UiToolkit:
    """Tool definitions plus approval state. ``send(proposal)`` is the caller's async sender, awaited once per
    approved proposal (never on Reject, never on replay). ``grounding="off"`` skips the numeric grounding check."""

    names = tuple(t["name"] for t in TOOL_DEFINITIONS)

    def __init__(self, send: Send | None = None, *, grounding: str = "on", email_approval_mode: str = "reply") -> None:
        if grounding not in ("on", "off"):
            raise ValueError("grounding must be 'on' or 'off'")
        self.send, self.grounding, self.email_approval_mode = send, grounding, email_approval_mode
        self.labels = dict(LABELS)
        self.decided: set[str] = set()
        self.proposals: dict[str, dict[str, Any]] = {}
        self.desk = ApprovalDesk(self.decide)

    @property
    def tools(self) -> list[dict[str, Any]]:
        """Responses API ``tools=`` entries (append to the caller's own tools)."""
        return [json.loads(json.dumps(t)) for t in TOOL_DEFINITIONS]

    def register(self, app: Any) -> None:
        self.desk.register(app)

    async def decide(self, approval_id: str, approved: bool, actor: str) -> CardInfo | None:
        """ApprovalDesk callback; also call it for an email-channel ``APPROVE <id>`` reply (then guard replays
        yourself with ``approval_id in toolkit.decided``)."""
        prop = self.proposals.get(approval_id)
        if prop is None:
            return None
        if approved and self.send is not None and approval_id not in self.decided:
            self.decided.add(approval_id)
            await self.send(prop)
        self.decided.add(approval_id)
        return CardInfo(f"Email: {prop['subject']}", f"To: {', '.join(prop['to'])}", {"Body": prop["body"][:500]})

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
        """Run a UI tool; returns the short tool result for the model (``rendered`` or an ``Error: ...``)."""
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
        return str(a.get("id") or f"{kind}:{title}")

    def _rows(self, a: Mapping[str, Any], key: str) -> list[Mapping[str, Any]]:
        rows = a[key]
        if not isinstance(rows, list) or not rows or not all(isinstance(r, Mapping) and "label" in r and "value" in r for r in rows):
            raise ValueError(f"{key} must be a non-empty list of {{label, value}}")
        return rows

    def _show_chart(self, a: Mapping[str, Any]) -> str:
        title, kind = str(a["title"]), a.get("kind")
        if kind not in ("bar", "donut"):
            return "Error: kind must be 'bar' or 'donut'."
        rows = self._rows(a, "series")
        if err := self._check(rows):
            return err
        series = [{"label": str(r["label"]), "value": _to_float(r["value"])} for r in rows]
        def render() -> None:
            if self.p.surface == "email":
                self.p.add_email_block(bar_table(title, series))
            else:
                self.p.add_card(bar_chart(title, series) if kind == "bar" else donut_chart(title, series))
        return self._enqueue(self._cid(a, "chart", title), render)

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
        details = {"To": ", ".join(to), **({"Cc": ", ".join(cc)} if cc else {}), "Body": body[:500]}
        def render() -> None:
            if self.p.surface == "email":
                self.p.add_email_block(approval_block(aid, f"Send email: {subject}", "Awaiting your approval.", details,
                                                      mode=self.kit.email_approval_mode))
            else:
                self.p.add_card(approval_card(aid, f"Send email: {subject}", "Awaiting your approval. Not sent yet.", details))
        return self._enqueue(cid, render).replace("queued", "queued as a draft; the email has NOT been sent", 1)
