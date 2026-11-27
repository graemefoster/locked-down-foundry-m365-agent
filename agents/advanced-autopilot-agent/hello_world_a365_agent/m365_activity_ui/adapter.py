"""OpenAI Responses stream (``responses.create(stream=True)``) -> TurnPresenter calls.

Events are read by shape (``type`` plus attributes or dict keys), so SDK objects, dicts and recordings all work.
"""
from __future__ import annotations

import json
import re
from typing import Any, AsyncIterable, Callable, Iterable, Mapping

from .citations import citations as make_citations
from .presenter import TurnPresenter
from .tool_cards import tool_step_label

_KINDS = {"function_call", "mcp_call", "web_search_call", "file_search_call"}


def _get(o: Any, k: str, default: Any = None) -> Any:
    return o.get(k, default) if isinstance(o, Mapping) else getattr(o, k, default)


def default_label(name: str, kind: str = "function_call") -> str:
    """``propose_reply`` -> ``Using propose reply...`` (never raw snake_case); built-in search calls get fixed
    phrases. Caller ``labels`` and the tool catalogue take precedence over this default."""
    if kind == "web_search_call":
        return "Searching the web..."
    if kind == "file_search_call":
        return "Searching documents..."
    words = re.sub(r"[_\-\s]+", " ", re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", name)).strip().lower()
    return f"Using {words}..." if words else "Working..."


def _catalogue(tools: Any) -> dict[str, Any]:
    """Tool catalogue as ``{name: entry}``: a mapping, or an iterable of entries (dicts with ``name`` / objects)."""
    if not tools:
        return {}
    if isinstance(tools, Mapping):
        return dict(tools)
    out: dict[str, Any] = {}
    for entry in tools:
        name = _get(entry, "name")
        if name:
            out[str(name)] = entry
    return out


def _arguments(item: Any) -> Any:
    args = _get(item, "arguments")
    if isinstance(args, str):
        try:
            return json.loads(args)
        except ValueError:
            return None
    return args


class ResponsesAdapter:
    """Maps events to presenter calls. ``labels`` maps tool name -> human step label (str, or callable taking the
    tool name); unmapped tools use ``default_label``. ``on_item_done(item)`` lets the caller turn a finished tool
    call (e.g. its output) into a card via ``presenter.add_card``. ``url_citation`` annotations become citations.
    ``tools`` is a tool catalogue (agentcraft-tools ``tool-catalog.json`` entries as a list or ``{name: entry}``, or
    view dicts); a known tool's step reads ``tool_step_label`` (title, subtitle filled from the call arguments),
    taking precedence over ``labels``; unknown tools fall back to ``labels``, then ``default_label``."""

    def __init__(self, presenter: TurnPresenter, labels: Mapping[str, str | Callable[[str], str]] | None = None,
                 on_item_done: Callable[[Any], None] | None = None,
                 tools: Mapping[str, Any] | Iterable[Any] | None = None) -> None:
        self.p = presenter
        self.tools = _catalogue(tools)
        self.labels = dict(labels or {})
        self.on_item_done = on_item_done
        self._sources: list[dict[str, str | None]] = []
        self._seen_urls: set[str] = set()
        self.usage: Any = None

    def label_for(self, item: Any) -> str:
        kind = _get(item, "type")
        name = _get(item, "name") or kind
        card = self.tools.get(name)
        if card is not None:
            return tool_step_label(card, _arguments(item), name=name)
        mapped = self.labels.get(name)
        if callable(mapped):
            return mapped(name)
        return mapped or default_label(name, kind)

    def handle(self, event: Any) -> None:
        t = _get(event, "type")
        if t == "response.output_item.added":
            item = _get(event, "item")
            if _get(item, "type") in _KINDS:
                self.p.step(self.label_for(item))
        elif t == "response.output_item.done":
            item = _get(event, "item")
            if self.on_item_done and _get(item, "type") in _KINDS:
                self.on_item_done(item)
        elif t == "response.output_text.delta":
            self.p.text(_get(event, "delta") or "")
        elif t == "response.output_text.annotation.added":
            a = _get(event, "annotation")
            url = _get(a, "url")
            if _get(a, "type") == "url_citation" and url and url not in self._seen_urls:
                self._seen_urls.add(url)
                self._sources.append({"title": _get(a, "title") or url, "url": url, "content": _get(a, "title") or url})
        elif t == "response.completed":
            self.usage = _get(_get(event, "response"), "usage")
        elif t in ("response.failed", "response.incomplete", "error"):
            raise RuntimeError(f"Responses stream ended with {t}")

    def finalize(self) -> None:
        if self._sources:
            self.p.add_citations(make_citations(self._sources))


async def present_responses(presenter: TurnPresenter, events: AsyncIterable[Any] | Iterable[Any],
                            labels: Mapping[str, str | Callable[[str], str]] | None = None,
                            on_item_done: Callable[[Any], None] | None = None,
                            tools: Mapping[str, Any] | Iterable[Any] | None = None) -> ResponsesAdapter:
    """Drive the presenter from a Responses event stream (async or plain iterable). Does not call ``finish``."""
    ad = ResponsesAdapter(presenter, labels, on_item_done, tools)
    if hasattr(events, "__aiter__"):
        async for e in events:  # type: ignore[union-attr]
            ad.handle(e)
    else:
        for e in events:  # type: ignore[union-attr]
            ad.handle(e)
    ad.finalize()
    return ad
