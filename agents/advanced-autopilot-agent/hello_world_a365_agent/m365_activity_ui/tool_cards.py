"""Adaptive Card 1.5 renderer for AgentCraft tool cards: the Activity Protocol sibling of ``@agentcraft/tool-ui``.

Input is plain data, so this module needs no agent-tools import: a catalogue entry (``tool-catalog.json`` tool, or the
dict from dumping a ``@tool_card``) or a bare ``OutputView`` dict (``{"kind", "body", "scope", ...}``), plus the tool's
result. Path grammar, view kinds (list, document, table, record, text) and formats mirror ``agentcraft_tools.contract``
and ``tool-ui/src/{paths,format,model}.ts``. Nothing here raises on odd input: an unknown or mismatched view falls back to a
key/value FactSet. Only ColumnSet / TextBlock / FactSet / Container are used (see cards.py).
"""
from __future__ import annotations

import dataclasses
import re
from typing import Any, Mapping

from .cards import adaptive_card

__all__ = ["VIEW_KINDS", "render_tool_card", "tool_step_label", "fill_subtitle", "resolve_path"]

VIEW_KINDS = ("list", "document", "table", "record", "text")
MISSING = "—"
MAX_LIST_ITEMS = 6      # a chat card, not a page: the view's own max_items still applies when lower
MAX_TABLE_ROWS = 10
MAX_TABLE_COLUMNS = 6
MAX_DOCUMENT_CHARS = 1500
MAX_FACTS = 12
MAX_WARNINGS = 3
MISMATCH_NOTE = "Output did not match the declared view"


# ---------------------------------------------------------------- data in

def _plain(value: Any) -> Any:
    """Dataclass / pydantic-style objects become dicts; dicts pass through."""
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        return dataclasses.asdict(value)
    dump = getattr(value, "model_dump", None)
    return dump(mode="json") if callable(dump) else value


def _view_of(card: Any) -> tuple[Mapping[str, Any], Mapping[str, Any]]:
    """(catalogue entry or {}, output view or {}) from an entry, a bare view or junk."""
    card = _plain(card)
    if not isinstance(card, Mapping):
        return {}, {}
    output = _plain(card.get("output"))
    if isinstance(output, Mapping):
        return card, output
    if "body" in card or "kind" in card:
        return {}, card
    return card, {}


# ---------------------------------------------------------------- paths (mirror of tool-ui paths.ts)

def _empty(value: Any) -> bool:
    return value is None or value == "" or value == []


def _walk(root: Any, path: str) -> Any:
    if path == "$":
        return root
    current = root
    for key in path.split("."):
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def resolve_path(root: Any, path: Any) -> Any:
    """``$`` is the root or current item; dotted keys walk objects only; a list of paths takes the first non-empty value."""
    if path is None:
        return None
    if isinstance(path, str):
        return _walk(root, path)
    if isinstance(path, (list, tuple)):
        for candidate in path:
            value = _walk(root, candidate) if isinstance(candidate, str) else None
            if not _empty(value):
                return value
    return None


# ---------------------------------------------------------------- formats (mirror of tool-ui format.ts)

def _num(value: float) -> str:
    text = f"{round(float(value), 2):,.2f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def _compact(value: float) -> str:
    for limit, suffix in ((1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")):
        if abs(value) >= limit:
            return f"{round(value / limit, 1):g}{suffix}"
    return _num(value)


def _scalar(value: Any) -> str:
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, (int, float)):
        return _num(value)
    if isinstance(value, str):
        return value
    try:
        import json
        return json.dumps(value, ensure_ascii=False, default=str)
    except (TypeError, ValueError):
        return str(value)


_ISO = re.compile(r"^(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2})(?::\d{2}(?:\.\d+)?)?)?(Z|[+-]\d{2}:?\d{2})?$")


def _iso(value: str, with_time: bool) -> str:
    match = _ISO.match(value.strip())
    if not match:
        return value
    date, time, zone = match.groups()
    if not with_time or not time:
        return date
    tz = " UTC" if zone in ("Z", "+00:00", "+0000") else f" {zone}" if zone else ""
    return f"{date} {time}{tz}"


def format_text(value: Any, fmt: str = "text") -> str:
    """Display text; the em dash when there is nothing to show."""
    if _empty(value):
        return MISSING
    number = value if isinstance(value, (int, float)) and not isinstance(value, bool) and value == value else None
    if fmt == "number":
        return _num(number) if number is not None else _scalar(value)
    if fmt == "compact":
        return _compact(number) if number is not None else _scalar(value)
    if fmt == "percent":
        return f"{_num(number)}%" if number is not None else _scalar(value)
    if fmt == "signed-percent":
        return f"{'+' if number > 0 else ''}{_num(number)}%" if number is not None else _scalar(value)
    if fmt == "bytes" and number is not None:
        if abs(number) < 1024:
            return f"{_num(number)} B"
        return f"{number / 1024:.1f} KB" if abs(number) < 1024 * 1024 else f"{number / 1024 / 1024:.1f} MB"
    if fmt in ("date", "datetime") and isinstance(value, str):
        return _iso(value, fmt == "datetime")
    if fmt == "list" and isinstance(value, list):
        return ", ".join(_scalar(item) for item in value)
    return _scalar(value)


def _is_url(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"https?://\S+", value, re.I) is not None


def _link(text: str, url: Any) -> str:
    safe = text.replace("[", "(").replace("]", ")")
    return f"[{safe}]({url})" if _is_url(url) and ")" not in str(url) else text


# ---------------------------------------------------------------- element helpers

def _text(text: str, **fields: Any) -> dict[str, Any]:
    return {"type": "TextBlock", "text": text or MISSING, "wrap": True, **fields}


def _small(text: str, **fields: Any) -> dict[str, Any]:
    return _text(text, size="Small", isSubtle=True, spacing="None", **fields)


def _facts(pairs: list[tuple[str, str]]) -> list[dict[str, Any]]:
    return [{"type": "FactSet", "facts": [{"title": str(k), "value": v} for k, v in pairs]}] if pairs else []


def _values(specs: Any, root: Any) -> list[tuple[str, str]]:
    """Declared labelled values; a missing field shows as the em dash, never drops silently."""
    out: list[tuple[str, str]] = []
    for spec in specs or []:
        if isinstance(spec, Mapping) and spec.get("label"):
            out.append((str(spec["label"]), format_text(resolve_path(root, spec.get("path")), spec.get("format") or "text")))
    return out


def _more(count: int, unit: str = "") -> dict[str, Any]:
    return _small(f"+{count} more{unit}")


def _string(root: Any, path: Any) -> str | None:
    value = resolve_path(root, path)
    return value if isinstance(value, str) and value.strip() else None


# ---------------------------------------------------------------- generic fallback

def _generic(result: Any, note: str | None = None) -> list[dict[str, Any]]:
    """Key/value FactSet of a result's top-level fields; scalars as text, containers summarised by size."""
    body: list[dict[str, Any]] = []
    if note:
        body.append(_small(note))
    if isinstance(result, Mapping):
        pairs: list[tuple[str, str]] = []
        for key, value in result.items():
            if isinstance(value, list):
                shown = f"{len(value)} item{'s' if len(value) != 1 else ''}"
            elif isinstance(value, Mapping):
                shown = f"{len(value)} field{'s' if len(value) != 1 else ''}"
            else:
                shown = format_text(value)
            pairs.append((str(key).replace("_", " "), shown))
        body += _facts(pairs[:MAX_FACTS])
        if len(pairs) > MAX_FACTS:
            body.append(_more(len(pairs) - MAX_FACTS))
        if not pairs:
            body.append(_text(MISSING))
    else:
        body.append(_text(format_text(result)[:MAX_DOCUMENT_CHARS]))
    return body


# ---------------------------------------------------------------- bodies

def _resolves(body: Mapping[str, Any], result: Any) -> bool:
    kind = body.get("kind")
    if kind == "list":
        return isinstance(resolve_path(result, body.get("items")), list)
    if kind == "document":
        return isinstance(resolve_path(result, body.get("text")), str)
    if kind == "table":
        if not isinstance(resolve_path(result, body.get("rows")), list):
            return False
        columns = body.get("columns")
        named = isinstance(columns, str) or (isinstance(columns, list) and all(isinstance(c, str) for c in columns))
        return isinstance(resolve_path(result, columns), list) if named else isinstance(columns, list)
    if kind == "record":
        return isinstance(result, dict)
    if kind == "text":
        value = resolve_path(result, body.get("text", "$"))
        return value is not None and not isinstance(value, (dict, list))
    return False


def _list_body(body: Mapping[str, Any], result: Any) -> list[dict[str, Any]]:
    items = resolve_path(result, body.get("items")) or []
    cap = min(int(body.get("max_items") or 20), MAX_LIST_ITEMS)
    out: list[dict[str, Any]] = []
    for item in items[:cap]:
        title = format_text(resolve_path(item, body.get("title")))
        title = "Untitled" if title == MISSING else title
        rank = resolve_path(item, body.get("rank"))
        head = _link(title, resolve_path(item, body.get("url")))
        if not _empty(rank):
            head = f"{format_text(rank, 'number')}. {head}"
        block: list[dict[str, Any]] = [_text(head, weight="Bolder")]
        snippet = _string(item, body.get("text"))
        if snippet:
            block.append(_text(snippet if len(snippet) <= 240 else snippet[:239].rstrip() + "…", spacing="None"))
        values = _values(body.get("values"), item)
        shown = [f"{k}: {v}" for k, v in values if v != MISSING]
        if shown:
            block.append(_small(" · ".join(shown)))
        out.append({"type": "Container", "separator": bool(out), "spacing": "Small", "items": block})
    if len(items) > len(out):
        out.append(_more(len(items) - len(out)))
    if not items:
        out.append(_small("No results"))
    return out


def _document_body(body: Mapping[str, Any], result: Any) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    title = _string(result, body.get("title"))
    if title:
        out.append(_text(_link(title, resolve_path(result, body.get("url"))), weight="Bolder"))
    out += _facts(_values(body.get("values"), result))
    text = resolve_path(result, body.get("text")) or ""
    limit = min(int(body.get("max_chars") or MAX_DOCUMENT_CHARS), MAX_DOCUMENT_CHARS)
    out.append(_text(text if len(text) <= limit else text[:limit].rstrip() + "…"))
    if len(text) > limit:
        out.append(_more(len(text) - limit, " characters"))
    return out


def _table_body(body: Mapping[str, Any], result: Any) -> list[dict[str, Any]]:
    rows = resolve_path(result, body.get("rows")) or []
    columns = body.get("columns")
    if isinstance(columns, list) and columns and all(isinstance(c, Mapping) for c in columns):
        labels = [str(c.get("label", "")) for c in columns]
        formats = [c.get("format") or "text" for c in columns]
        data = [[resolve_path(row, c.get("path")) for c in columns] for row in rows]
    else:
        names = resolve_path(result, columns) or []
        labels = [str(n).replace("_", " ") for n in names]
        formats = ["text"] * len(labels)
        data = [[row[i] if isinstance(row, list) and i < len(row) else None for i in range(len(labels))] for row in rows]
    if not labels:
        return _generic(result, MISMATCH_NOTE)
    hidden = max(0, len(labels) - MAX_TABLE_COLUMNS)
    labels, formats = labels[:MAX_TABLE_COLUMNS], formats[:MAX_TABLE_COLUMNS]
    shown = data[:min(int(body.get("max_rows") or 50), MAX_TABLE_ROWS)]

    def row_set(cells: list[str], header: bool, numeric: list[bool]) -> dict[str, Any]:
        return {"type": "ColumnSet", "separator": header, "spacing": "Small", "columns": [
            {"type": "Column", "width": "stretch", "items": [
                _text(cell, weight="Bolder" if header else "Default", size="Small",
                      horizontalAlignment="Right" if numeric[i] else "Left")]}
            for i, cell in enumerate(cells)]}

    numeric = [bool(shown) and all(r[i] is None or isinstance(r[i], (int, float)) and not isinstance(r[i], bool) for r in shown)
               for i in range(len(labels))]
    out = [row_set(labels, True, [False] * len(labels))]
    out += [row_set([format_text(v, formats[i]) for i, v in enumerate(r[:len(labels)])], False, numeric) for r in shown]
    if not shown:
        out.append(_small("No rows"))
    if len(data) > len(shown):
        out.append(_more(len(data) - len(shown), " rows"))
    if hidden:
        out.append(_small(f"+{hidden} more column{'s' if hidden != 1 else ''} not shown"))
    return out


def _body(body: Mapping[str, Any], result: Any) -> list[dict[str, Any]]:
    kind = body.get("kind")
    if kind == "list":
        return _list_body(body, result)
    if kind == "document":
        return _document_body(body, result)
    if kind == "table":
        return _table_body(body, result)
    if kind == "record":
        return _facts(_values(body.get("values"), result)) or _generic(result)
    return [_text(format_text(resolve_path(result, body.get("text", "$"))))]


# ---------------------------------------------------------------- public

def fill_subtitle(template: str | None, arguments: Any) -> str | None:
    """Fill ``{param}`` placeholders from the call arguments; a missing, empty or non-scalar value omits the subtitle."""
    if not template:
        return None
    args = arguments if isinstance(arguments, Mapping) else {}
    missing = False

    def fill(match: re.Match[str]) -> str:
        nonlocal missing
        value = args.get(match.group(1))
        if _empty(value) or isinstance(value, (dict, list)):
            missing = True
            return ""
        return str(value)

    text = re.sub(r"\{(\w+)\}", fill, template)
    return None if missing or not text.strip() else text


def tool_step_label(card: Any, arguments: Any = None, *, done: bool = False, name: str | None = None) -> str:
    """Progress-line text from a tool card's human metadata: ``Web search: NVIDIA earnings`` (``… done`` when finished).
    Falls back to the tool name, then ``Tool``; never raises."""
    try:
        entry, _ = _view_of(card)
        title = str(entry.get("title") or "").strip() or (name or str(entry.get("name") or "")).replace("_", " ").strip().capitalize() or "Tool"
        sub = fill_subtitle(entry.get("subtitle"), arguments)
        label = f"{title}: {sub[:80]}" if sub else title
        return f"{label} (done)" if done else label
    except Exception:  # a label must never break a turn
        return "Tool"


def render_tool_card(card: Any, result: Any, arguments: Any = None) -> dict[str, Any]:
    """Adaptive Card 1.5 for one tool result read through the tool card's declared output view.

    ``card`` is a catalogue entry (title/subtitle/output) or a bare output-view dict; ``arguments`` fills the subtitle.
    Unknown view kind, mismatched result or any internal fault yields a generic key/value card; never raises."""
    try:
        entry, view = _view_of(card)
        body: list[dict[str, Any]] = []
        title = str(entry.get("title") or "").strip()
        if title:
            body.append(_text(title, weight="Bolder", size="Medium"))
            sub = fill_subtitle(entry.get("subtitle"), arguments)
            if sub:
                body.append(_small(sub))
        body += _view_body(view, result)
        return adaptive_card(body)
    except Exception:
        return adaptive_card(_generic(result))


def _view_body(view: Mapping[str, Any], result: Any) -> list[dict[str, Any]]:
    inner = view.get("body")
    inner = inner if isinstance(inner, Mapping) else {}
    kind = view.get("kind") or inner.get("kind")
    if kind not in VIEW_KINDS or inner.get("kind", kind) != kind:
        return _generic(result)
    out: list[dict[str, Any]] = []
    lead = _string(result, view.get("lead"))
    if lead:
        out.append(_text(lead))
    bands = _values(view.get("scope"), result) + _values(view.get("signals"), result)
    out += _facts(bands)
    if _resolves(inner, result):
        out += _body(inner, result)
    else:
        out += _generic(result, MISMATCH_NOTE)
    note = _string(result, view.get("note"))
    if note:
        out.append(_small(note))
    raw = resolve_path(result, view.get("warnings"))
    warnings = [raw] if isinstance(raw, str) else [w for w in raw if isinstance(w, str)] if isinstance(raw, list) else []
    for warning in [w for w in warnings if w.strip()][:MAX_WARNINGS]:
        out.append(_text(warning, size="Small", color="Warning"))
    return out
