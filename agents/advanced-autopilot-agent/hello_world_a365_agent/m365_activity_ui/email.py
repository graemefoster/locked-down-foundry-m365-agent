"""Email-safe HTML renderers for an autopilot agent replying from its own mailbox.

Outlook desktop renders with the Word engine, so output is table layout with inline styles only: no flex,
grid, SVG, script, ``<style>``, external CSS or web fonts; width at most 600 px; system font stack.
Every renderer returns an :class:`EmailBlock` ``(html, text)`` so each HTML fragment has a plain-text twin.
Inputs match the chat components (``kpi_strip`` items, ``bar_chart``/``donut_chart`` series, ``citations``
items, ``approval_card`` fields), so one computed data source feeds both the card and the email.
All caller text is escaped. Approval modes: ``"reply"`` (default) and ``"link"``; the ``mode`` seam is where
an Actionable Message variant would slot in (not built).
"""
from __future__ import annotations

import html
import re
from typing import Any, Iterable, Mapping, NamedTuple, Sequence

from .charts import DEFAULT_MAX_CATEGORIES, _num, _top_n
from .formatting import markdown_to_html

WIDTH = 600
FONT = "font-family:Segoe UI,Helvetica,Arial,sans-serif;"
_TONE = {"good": "#107c10", "warning": "#8a6100", "bad": "#a4262c", "accent": "#0f6cbd"}
_INK, _SUBTLE, _BAR, _TRACK, _RULE = "#242424", "#616161", "#0f6cbd", "#e8e8e8", "#d1d1d1"
_ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")


class EmailBlock(NamedTuple):
    html: str
    text: str


def _e(value: Any) -> str:
    return html.escape(str(value), quote=True)


def _heading(title: str) -> str:
    return (f'<p style="margin:0 0 8px 0;{FONT}font-size:15px;font-weight:bold;color:{_INK};">{_e(title)}</p>')


def _wrap(inner: str) -> str:
    return (f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" '
            f'style="margin:0 0 20px 0;"><tr><td style="{FONT}font-size:14px;color:{_INK};">{inner}</td></tr></table>')


def figures_table(items: Iterable[Mapping[str, Any]], *, title: str | None = None) -> EmailBlock:
    """KPI figures (same items as ``kpi_strip``: ``label``, ``value``, optional ``delta``, ``tone``) as a
    label | value | change table."""
    rows, lines = [], []
    for it in items:
        color = _TONE.get(str(it.get("tone") or ""), _INK)
        delta = str(it.get("delta") or "")
        cell = f"padding:6px 8px;border-bottom:1px solid {_RULE};{FONT}font-size:14px;"
        rows.append(f'<tr><td style="{cell}color:{_SUBTLE};">{_e(it["label"])}</td>'
                    f'<td align="right" style="{cell}font-weight:bold;color:{color};">{_e(it["value"])}</td>'
                    f'<td align="right" style="{cell}color:{color};">{_e(delta)}</td></tr>')
        lines.append(f"  {it['label']}: {it['value']}" + (f" ({delta})" if delta else ""))
    table = (f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" '
             f'style="border-collapse:collapse;">{"".join(rows)}</table>')
    head = _heading(title) if title else ""
    text = (f"{title}\n" if title else "") + "\n".join(lines)
    return EmailBlock(_wrap(head + table), text)


def bar_table(title: str, series: Sequence[Mapping[str, Any]], *,
              max_categories: int = DEFAULT_MAX_CATEGORIES) -> EmailBlock:
    """Bars as table rows with proportional cell widths and the value printed. ``series`` is what
    ``bar_chart`` (``{label, value}``, or multi ``{name, values}`` summed per label) or ``donut_chart``
    (``[{label, value}]``; email has no native chart, so a donut renders as bars) takes."""
    totals: dict[str, float] = {}
    for s in series:
        if "values" in s:
            for k, v in dict(s["values"] or {}).items():
                totals[str(k)] = totals.get(str(k), 0.0) + float(v)
        else:
            totals[str(s["label"])] = totals.get(str(s["label"]), 0.0) + float(s["value"])
    pairs = _top_n([(k, v) for k, v in totals.items() if v > 0], max_categories)
    if not pairs:
        return EmailBlock(_wrap(_heading(title) + f'<p style="margin:0;color:{_SUBTLE};">No data</p>'),
                          f"{title}\n  No data")
    peak = max(v for _, v in pairs)
    cell = f"padding:4px 8px;{FONT}font-size:13px;"
    rows, lines = [], []
    for label, v in pairs:
        pct = max(1, min(100, round(100 * v / peak)))
        rest = 100 - pct
        track = (f'<td width="{rest}%" bgcolor="{_TRACK}" style="background-color:{_TRACK};font-size:1px;line-height:14px;">'
                 f'&nbsp;</td>') if rest else ""
        bar = (f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>'
               f'<td width="{pct}%" bgcolor="{_BAR}" style="background-color:{_BAR};font-size:1px;line-height:14px;">'
               f'&nbsp;</td>{track}</tr></table>')
        rows.append(f'<tr><td width="30%" style="{cell}color:{_INK};">{_e(label)}</td>'
                    f'<td width="50%" style="{cell}">{bar}</td>'
                    f'<td width="20%" align="right" style="{cell}font-weight:bold;color:{_INK};">{_e(_num(v))}</td></tr>')
        lines.append(f"  {label}: {_num(v)}")
    table = (f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">'
             f'{"".join(rows)}</table>')
    return EmailBlock(_wrap(_heading(title) + table), f"{title}\n" + "\n".join(lines))


def sources_footnotes(items: Iterable[Mapping[str, Any]], *, title: str = "Sources") -> EmailBlock:
    """Numbered footnotes from ``citations`` items (``title``, ``url``); ``[n]`` matches the n-th item.
    Only http(s) URLs become links."""
    rows, lines = [], []
    for n, it in enumerate(items, 1):
        name, url = str(it.get("title") or it.get("url") or ""), str(it.get("url") or "")
        label = _e(name)
        if re.match(r"https?://", url):
            label = f'<a href="{_e(url)}" style="color:{_BAR};">{label}</a>'
        rows.append(f'<tr><td valign="top" width="28" style="padding:2px 0;{FONT}font-size:12px;color:{_SUBTLE};">[{n}]</td>'
                    f'<td style="padding:2px 0;{FONT}font-size:12px;color:{_SUBTLE};">{label}</td></tr>')
        lines.append(f"  [{n}] {name}" + (f" - {url}" if re.match(r"https?://", url) and url != name else ""))
    if not rows:
        return EmailBlock("", "")
    table = f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">{"".join(rows)}</table>'
    return EmailBlock(_wrap(_heading(title) + table), f"{title}\n" + "\n".join(lines))


def _check_id(approval_id: str) -> str:
    if not _ID_RE.match(approval_id):
        raise ValueError("approval id must be 1-64 characters of letters, digits, '_', '.', '-'")
    return approval_id


def _button(label: str, url: str, color: str) -> str:
    return (f'<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="display:inline-table;"><tr>'
            f'<td bgcolor="{color}" style="background-color:{color};padding:8px 18px;">'
            f'<a href="{_e(url)}" style="{FONT}font-size:14px;font-weight:bold;color:#ffffff;text-decoration:none;">'
            f'{_e(label)}</a></td></tr></table>&nbsp;')


def approval_block(id: str, title: str, summary: str, details: Mapping[str, Any] | None = None, *,
                   mode: str = "reply", approve_url: str | None = None,
                   reject_url: str | None = None) -> EmailBlock:
    """Approval request. ``mode="reply"`` (default) asks the user to reply ``APPROVE <id>`` or ``REJECT <id>``
    (read with :func:`parse_approval_reply`). ``mode="link"`` renders two buttons to the caller-supplied
    https URLs (both required). Other modes raise ``ValueError``; an Actionable Message variant is not built."""
    _check_id(id)
    facts = "".join(
        f'<tr><td style="padding:3px 8px 3px 0;{FONT}font-size:13px;color:{_SUBTLE};">{_e(k)}</td>'
        f'<td style="padding:3px 0;{FONT}font-size:13px;color:{_INK};">{_e(v)}</td></tr>'
        for k, v in (details or {}).items())
    facts_html = (f'<table role="presentation" cellpadding="0" cellspacing="0" border="0" '
                  f'style="margin:0 0 10px 0;">{facts}</table>') if facts else ""
    text = [title, f"  {summary}", *(f"  {k}: {v}" for k, v in (details or {}).items())]
    if mode == "reply":
        action = (f'<p style="margin:0;{FONT}font-size:14px;color:{_INK};">To decide, reply to this email with exactly '
                  f'<strong>APPROVE {_e(id)}</strong> or <strong>REJECT {_e(id)}</strong> on the first line.</p>')
        text.append(f"To decide, reply with exactly 'APPROVE {id}' or 'REJECT {id}' on the first line.")
    elif mode == "link":
        for u in (approve_url, reject_url):
            if not u or not u.startswith("https://"):
                raise ValueError("link mode needs https approve_url and reject_url")
        action = _button("Approve", approve_url, "#107c10") + _button("Reject", reject_url, "#a4262c")  # type: ignore[arg-type]
        text += [f"Approve: {approve_url}", f"Reject: {reject_url}"]
    else:
        raise ValueError(f"unknown approval mode: {mode}")
    box = (f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" '
           f'style="border:1px solid {_RULE};"><tr><td style="padding:12px;{FONT}font-size:14px;color:{_INK};">'
           f'{_heading(title)}<p style="margin:0 0 10px 0;">{_e(summary)}</p>{facts_html}{action}</td></tr></table>')
    return EmailBlock(_wrap(box), "\n".join(text))


_HTML_CUT = re.compile(r"<hr\b|<blockquote\b|<div[^>]+id=[\"']?(?:appendonsend|divRplyFwdMsg)", re.IGNORECASE)
_TEXT_CUT = re.compile(r"^\s*(?:From:|-{2,}\s*Original Message|On\b.{0,250}?wrote:)", re.IGNORECASE | re.MULTILINE | re.DOTALL)


def reply_top(body: str) -> str:
    """The new text of a reply as plain text: HTML cut at quoted-history markers (``<hr>``, ``<blockquote>``,
    ``appendonsend``), tags stripped, then cut again at ``From:``, ``-----Original Message-----`` or
    ``On ... wrote:``. Works on plain-text bodies too."""
    body = body or ""
    m = _HTML_CUT.search(body)
    if m:
        body = body[:m.start()]
    body = re.sub(r"(?is)<(script|style|head)\b.*?</\1>", "", body)
    body = re.sub(r"(?i)<br\s*/?>|</(p|div|tr|li|h\d)>", "\n", body)
    text = html.unescape(re.sub(r"<[^>]*>", "", body)).replace("\xa0", " ")
    m = _TEXT_CUT.search(text)
    return text[:m.start()] if m else text


def parse_approval_reply(body: str, expected_id: str) -> str | None:
    """Read a reply to :func:`approval_block`: ``"approve"``, ``"reject"`` or ``None``.

    ``body`` is the notification ``html_body`` (or plain text); it includes quoted history, so only the new top
    portion is read (:func:`reply_top`). Its first non-blank line must be exactly ``APPROVE <id>`` or
    ``REJECT <id>`` (verb case-insensitive, id exact, optional trailing full stop). A quoted ``>`` line, wrong id,
    extra words and anything else give ``None`` so the caller refuses rather than guesses."""
    for line in reply_top(body).splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.fullmatch(r"(APPROVE|REJECT)\s+([A-Za-z0-9_.-]{1,64}?)\.?", line, re.IGNORECASE)
        if m and m.group(2) == expected_id:
            return m.group(1).lower()
        return None
    return None


def _md_text(md: str) -> str:
    md = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r"\1 (\2)", md)
    return re.sub(r"\*\*(.+?)\*\*", r"\1", md).strip()


def _style_markdown(md: str) -> str:
    base = f'style="margin:0 0 12px 0;{FONT}font-size:14px;line-height:20px;color:{_INK};"'
    out = markdown_to_html(md)
    return out.replace("<p>", f"<p {base}>").replace("<ul>", f'<ul {base}>')


def email_reply(subject: str | None, intro_md: str, blocks: Sequence[EmailBlock | tuple[str, str]],
                sign_off: str) -> tuple[str, str]:
    """Compose the reply: ``(html, text)``. The Agent 365 ``EmailResponse`` carries only ``html_body`` (no subject,
    recipients or attachments), so ``subject`` is optional and only an in-body heading; pass ``html`` as
    ``html_body`` and keep ``text`` for logs and tests. ``intro_md`` (small markdown
    subset), ``blocks`` (renderer outputs, in order) and ``sign_off`` are escaped; blocks are already escaped by
    their renderers, so pass only :class:`EmailBlock` values from this module."""
    body = [f'<p style="margin:0 0 12px 0;{FONT}font-size:20px;font-weight:bold;color:{_INK};">{_e(subject)}</p>'
            if subject else "", _style_markdown(intro_md) if intro_md.strip() else ""]
    parts = [subject] if subject else []
    if intro_md.strip():
        parts += [""] * bool(parts) + [_md_text(intro_md)]
    for b in blocks:
        h, t = b
        body.append(h)
        if t:
            parts += ["", t]
    sign = "<br>".join(_e(line) for line in sign_off.strip().splitlines())
    body.append(f'<p style="margin:0;{FONT}font-size:14px;color:{_INK};">{sign}</p>')
    parts += ["", sign_off.strip()]
    doc = ('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">'
           f'<title>{_e(subject or "")}</title></head><body style="margin:0;padding:0;background-color:#ffffff;">'
           f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr><td align="center">'
           f'<table role="presentation" width="{WIDTH}" cellpadding="0" cellspacing="0" border="0" '
           f'style="width:{WIDTH}px;max-width:{WIDTH}px;"><tr><td style="padding:16px;">{"".join(body)}</td></tr></table>'
           f'</td></tr></table></body></html>')
    return doc, "\n".join(parts).strip() + "\n"
