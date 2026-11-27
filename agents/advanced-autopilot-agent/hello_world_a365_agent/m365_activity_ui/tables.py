"""Table cards (Adaptive Card 1.5 ``Table`` element, supported in Teams) and M365 deep-link helpers.

Fallback choice: none. ``Table`` is AC 1.5 and Teams renders it; hosts without it show the card's
``fallbackText`` only, which we do not synthesise. Use ``cards.kpi_strip`` when a ColumnSet is wanted.
Only ``https`` URLs are ever emitted (``ValueError`` otherwise).
"""
from __future__ import annotations

from typing import Any, Iterable, Mapping, Sequence
from urllib.parse import quote, urlsplit

from .cards import adaptive_card

DEFAULT_MAX_ROWS = 10
_MD_ESCAPE = str.maketrans({c: "\\" + c for c in "\\[]()*_`"})


def require_https(url: str) -> str:
    """Return ``url`` if it is an absolute https URL with a host, else raise ``ValueError``."""
    parts = urlsplit(str(url).strip())
    if parts.scheme != "https" or not parts.netloc or any(c.isspace() for c in str(url).strip()):
        raise ValueError(f"only absolute https URLs are allowed: {url!r}")
    return str(url).strip()


def outlook_message_url(web_link: str | None = None, *, item_id: str | None = None) -> str:
    """Link to an Outlook message. Prefer Graph's ``webLink`` (pass it through, https-checked).

    ``webLink``: https://learn.microsoft.com/graph/api/resources/message (property ``webLink``).
    Fallback from a REST/Graph item id (the ``ItemID`` OWA deep-link form, not formally documented by
    Microsoft; prefer ``webLink``): ``https://outlook.office.com/owa/?ItemID=<id>&exvsurl=1&viewmodel=ReadMessageItem``.
    """
    if web_link:
        return require_https(web_link)
    if not item_id:
        raise ValueError("need web_link or item_id")
    return f"https://outlook.office.com/owa/?ItemID={quote(item_id, safe='')}&exvsurl=1&viewmodel=ReadMessageItem"


def outlook_event_url(web_link: str | None = None, *, event_id: str | None = None) -> str:
    """Link to an Outlook calendar event. Prefer Graph's ``webLink``
    (https://learn.microsoft.com/graph/api/resources/event). Fallback from an event id:
    ``https://outlook.office.com/owa/?itemid=<id>&exvsurl=1&path=/calendar/item`` (OWA form, not formally documented).
    """
    if web_link:
        return require_https(web_link)
    if not event_id:
        raise ValueError("need web_link or event_id")
    return f"https://outlook.office.com/owa/?itemid={quote(event_id, safe='')}&exvsurl=1&path=/calendar/item"


def teams_chat_url(users: Iterable[str], *, topic: str | None = None, message: str | None = None) -> str:
    """Deep link opening (or creating) a Teams chat with ``users`` (UPNs/emails).

    Documented: https://learn.microsoft.com/microsoftteams/platform/concepts/build-and-test/deep-link-teams
    (``https://teams.microsoft.com/l/chat/0/0?users=<a>,<b>&topicName=..&message=..``).
    """
    upns = [u.strip() for u in users if u and u.strip()]
    if not upns or any("@" not in u or any(c.isspace() or c == "," for c in u) for u in upns):
        raise ValueError("users must be a non-empty list of UPNs/emails")
    url = "https://teams.microsoft.com/l/chat/0/0?users=" + ",".join(quote(u, safe="@") for u in upns)
    if topic:
        url += "&topicName=" + quote(topic, safe="")
    if message:
        url += "&message=" + quote(message, safe="")
    return url


def _cell(text: Any, *, header: bool = False) -> dict[str, Any]:
    block: dict[str, Any] = {"type": "TextBlock", "text": "" if text is None else str(text), "wrap": True}
    if header:
        block["weight"] = "Bolder"
    return {"type": "TableCell", "items": [block]}


def _row(values: Sequence[Any], *, header: bool = False) -> dict[str, Any]:
    return {"type": "TableRow", "cells": [_cell(v, header=header) for v in values]}


def table_card(
    title: str | None,
    columns: Sequence[str | Mapping[str, Any]],
    rows: Sequence[Mapping[str, Any] | Sequence[Any]],
    *,
    links: Sequence[str | None] | None = None,
    link_title: str = "Open",
    link_mode: str = "column",
    max_rows: int = DEFAULT_MAX_ROWS,
) -> dict[str, Any]:
    """Adaptive Card with a ``Table``.

    ``columns``: header strings, or ``{"title", "key"?, "width"?}`` (``key`` selects from dict rows, default
    title). ``rows``: sequences, or mappings keyed by column key. At most ``max_rows`` rows are shown, then a
    "+N more" line. ``links``: one https URL (or None) per row, parallel to ``rows``. ``link_mode="column"``
    appends a markdown-link column; ``"actions"`` adds up to 6 card-level ``Action.OpenUrl`` (Teams limit),
    titled by the row's first cell. Invalid (non-https) URLs raise ``ValueError``.
    """
    if link_mode not in ("column", "actions"):
        raise ValueError(f"unknown link_mode: {link_mode}")
    if max_rows < 1:
        raise ValueError("max_rows must be >= 1")
    cols = [{"title": c} if isinstance(c, str) else dict(c) for c in columns]
    if not cols:
        raise ValueError("columns required")
    if links is not None and len(links) != len(rows):
        raise ValueError("links must be parallel to rows")
    urls = [require_https(u) if u else None for u in (links or [None] * len(rows))]

    shown = rows[:max_rows]
    matrix: list[list[Any]] = []
    for r in shown:
        if isinstance(r, Mapping):
            matrix.append([r.get(c.get("key", c["title"])) for c in cols])
        else:
            vals = list(r)
            matrix.append((vals + [None] * len(cols))[: len(cols)])

    with_col = links is not None and link_mode == "column"
    header = [c["title"] for c in cols] + ([link_title] if with_col else [])
    table_rows = [_row(header, header=True)]
    for vals, url in zip(matrix, urls):
        if with_col:
            vals = vals + [f"[{link_title.translate(_MD_ESCAPE)}]({url})" if url else ""]
        table_rows.append(_row(vals))
    table_cols = [{"width": c.get("width", 1)} for c in cols] + ([{"width": 1}] if with_col else [])

    body: list[dict[str, Any]] = []
    if title:
        body.append({"type": "TextBlock", "text": title, "weight": "Bolder", "wrap": True})
    body.append({"type": "Table", "columns": table_cols, "rows": table_rows, "firstRowAsHeader": True,
                 "showGridLines": True})
    hidden = len(rows) - len(shown)
    if hidden > 0:
        body.append({"type": "TextBlock", "text": f"+{hidden} more", "isSubtle": True, "size": "Small",
                     "wrap": True})
    card = adaptive_card(body)
    if links is not None and link_mode == "actions":
        card["actions"] = [
            {"type": "Action.OpenUrl", "title": (str(vals[0]) if vals and vals[0] is not None else link_title)[:100],
             "url": url}
            for vals, url in zip(matrix, urls) if url
        ][:6]
    return card
