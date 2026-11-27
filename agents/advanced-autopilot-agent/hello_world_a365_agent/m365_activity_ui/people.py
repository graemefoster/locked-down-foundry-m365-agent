"""People card: Teams Persona / PersonaSet Components, or a plain ColumnSet fallback.

Component shape per https://learn.microsoft.com/en-us/microsoftteams/platform/task-modules-and-cards/cards/cards-format#people-icon-in-an-adaptive-card
(``type: Component``, ``name: graph.microsoft.com/user`` or ``/users``, ``view: compact``, ``properties`` with
``id``, ``displayName``, ``userPrincipalName``; style not customisable; a PersonaSet shows only avatars).
Default render is the fallback: Persona is a Teams-specific Component and is unverified in M365 Copilot and
Agents Playground, where an unknown element may drop the whole card; the ColumnSet renders everywhere.
"""
from __future__ import annotations

import re
from typing import Any, Iterable, Mapping
from urllib.parse import quote

from .cards import adaptive_card

_MD_SPECIAL = re.compile(r"([\\`*_{}\[\]()#+!|<>~])")
_EMAIL = re.compile(r"^[^\s@<>()\[\]\"',;:]+@[^\s@<>()\[\]\"',;:]+\.[^\s@<>()\[\]\"',;:]+$")
RENDERS = ("fallback", "persona", "persona_set")


def _md(text: Any) -> str:
    return _MD_SPECIAL.sub(r"\\\1", str(text))


def _address(person: Mapping[str, Any]) -> str:
    addr = str(person.get("upn") or person.get("email") or "").strip()
    return addr if _EMAIL.match(addr) else ""


def _initials(name: str) -> str:
    parts = [p for p in re.split(r"[\s.@_-]+", name) if p]
    if not parts:
        return "?"
    letters = parts[0][0] + (parts[-1][0] if len(parts) > 1 else "")
    return letters.upper()


def _clean(people: Iterable[Mapping[str, Any]] | None) -> list[Mapping[str, Any]]:
    return [p for p in (people or []) if str(p.get("name") or "").strip() or _address(p)]


def _detail(person: Mapping[str, Any]) -> str:
    return " · ".join(_md(person[k]) for k in ("role", "note") if person.get(k))


def _persona_props(person: Mapping[str, Any]) -> dict[str, Any]:
    props: dict[str, Any] = {"displayName": str(person.get("name") or _address(person))}
    if person.get("id"):
        props["id"] = str(person["id"])
    if _address(person):
        props["userPrincipalName"] = _address(person)
    return props


def _fallback_row(person: Mapping[str, Any]) -> dict[str, Any]:
    name = str(person.get("name") or _address(person))
    addr = _address(person)
    lines: list[dict[str, Any]] = [{"type": "TextBlock", "text": _md(name), "weight": "Bolder", "wrap": True,
                                    "spacing": "None"}]
    if _detail(person):
        lines.append({"type": "TextBlock", "text": _detail(person), "isSubtle": True, "size": "Small",
                      "wrap": True, "spacing": "None"})
    if addr:
        q = quote(addr, safe="@")
        lines.append({"type": "TextBlock", "size": "Small", "wrap": True, "spacing": "None",
                      "text": f"[Email](mailto:{q}) · [Chat in Teams](https://teams.microsoft.com/l/chat/0/0?users={q})"})
    return {"type": "ColumnSet", "spacing": "Small", "columns": [
        {"type": "Column", "width": "auto", "verticalContentAlignment": "Center", "items": [
            {"type": "TextBlock", "text": _initials(name), "weight": "Bolder", "color": "Accent"}]},
        {"type": "Column", "width": "stretch", "items": lines}]}


def people_card(title: str, people: Iterable[Mapping[str, Any]] | None, *,
                render: str = "fallback") -> dict[str, Any] | None:
    """Card listing people, or ``None`` when there are none (send prose instead of an empty card).

    Each person: ``name``, ``email`` or ``upn`` (optional ``id`` Entra object id), optional ``role``, ``note``.
    ``render``: ``"fallback"`` (default, ColumnSet with initials, name, mailto and Teams chat links),
    ``"persona"`` (one ``graph.microsoft.com/user`` Component per person, role/note beneath) or
    ``"persona_set"`` (one ``graph.microsoft.com/users`` avatar row). Persona modes are Teams-only, unverified
    in Copilot/Playground."""
    if render not in RENDERS:
        raise ValueError(f"unknown render: {render}")
    rows = _clean(people)
    if not rows:
        return None
    body: list[dict[str, Any]] = [{"type": "TextBlock", "text": title, "weight": "Bolder", "wrap": True}]
    if render == "persona_set":
        body.append({"type": "Component", "name": "graph.microsoft.com/users", "view": "compact",
                     "properties": {"users": [_persona_props(p) for p in rows]}})
    elif render == "persona":
        for p in rows:
            body.append({"type": "Component", "name": "graph.microsoft.com/user", "view": "compact",
                         "properties": _persona_props(p)})
            if _detail(p):
                body.append({"type": "TextBlock", "text": _detail(p), "isSubtle": True, "size": "Small",
                             "wrap": True, "spacing": "None"})
    else:
        body.extend(_fallback_row(p) for p in rows)
    return adaptive_card(body)
