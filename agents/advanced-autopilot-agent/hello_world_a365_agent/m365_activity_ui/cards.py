"""Pure dict builders for Adaptive Card 1.5 (ColumnSet / TextBlock only: Copilot support for Chart/Badge is unknown)."""
from __future__ import annotations

from typing import Any, Iterable, Mapping

ADAPTIVE_CARD_CONTENT_TYPE = "application/vnd.microsoft.card.adaptive"
_TONE_COLOR = {"good": "Good", "warning": "Warning", "bad": "Attention", "accent": "Accent"}


def adaptive_card(body: list[dict[str, Any]]) -> dict[str, Any]:
    """Wrap body elements in an Adaptive Card 1.5 envelope."""
    return {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.5",
        "body": body,
    }


def kpi_strip(items: Iterable[Mapping[str, Any]], *, title: str | None = None) -> dict[str, Any]:
    """A row of KPI tiles. Each item: ``label``, ``value``, optional ``delta`` text and ``tone``
    (good|warning|bad|accent). One equal-width column per item, so keep to about four."""
    columns: list[dict[str, Any]] = []
    for item in items:
        color = _TONE_COLOR.get(str(item.get("tone") or ""), "Default")
        tile: list[dict[str, Any]] = [
            {"type": "TextBlock", "text": str(item["value"]), "size": "ExtraLarge", "weight": "Bolder",
             "color": color, "wrap": True},
            {"type": "TextBlock", "text": str(item["label"]), "size": "Small", "isSubtle": True,
             "spacing": "None", "wrap": True},
        ]
        if item.get("delta"):
            tile.append({"type": "TextBlock", "text": str(item["delta"]), "size": "Small", "color": color,
                         "spacing": "None", "wrap": True})
        columns.append({"type": "Column", "width": "stretch", "items": tile})
    body: list[dict[str, Any]] = []
    if title:
        body.append({"type": "TextBlock", "text": title, "weight": "Bolder", "wrap": True})
    body.append({"type": "ColumnSet", "columns": columns})
    return adaptive_card(body)


PROMPT_VERB = "prompt"


def prompt_actions(prompts: Iterable[str], mode: str = "execute") -> list[dict[str, Any]]:
    """Card actions that send each prompt as the user's next message.

    ``mode="execute"`` (default): ``Action.Execute`` verb ``prompt`` with data ``{"prompt": ...}``; works in Agents
    Playground and Teams, needs ``PromptDesk`` registered. ``mode="imback"``: Teams ``imBack`` via
    ``Action.Submit`` (no server code, but Agents Playground ignores it)."""
    if mode == "imback":
        return [{"type": "Action.Submit", "title": p[:100], "data": {"msteams": {"type": "imBack", "value": p}}}
                for p in prompts]
    if mode != "execute":
        raise ValueError(f"unknown prompt mode: {mode}")
    return [{"type": "Action.Execute", "title": p[:100], "verb": PROMPT_VERB, "data": {"prompt": p}}
            for p in prompts]


def with_actions(card: Mapping[str, Any], actions: list[dict[str, Any]]) -> dict[str, Any]:
    """Copy of ``card`` with ``actions`` appended to its top-level actions."""
    out = dict(card)
    out["actions"] = [*card.get("actions", []), *actions]
    return out
