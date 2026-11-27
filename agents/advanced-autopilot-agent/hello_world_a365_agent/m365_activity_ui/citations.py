"""Citation helper: SDK ``Citation`` objects whose abstract already fits Teams' 160-character limit."""
from __future__ import annotations

from typing import Iterable, Mapping

from microsoft_agents.hosting.core.app.streaming import Citation

TEAMS_ABSTRACT_LIMIT = 160  # the SDK clips at 480, which Teams rejects


def clip(text: str, limit: int = TEAMS_ABSTRACT_LIMIT) -> str:
    """Whole-word clip to at most ``limit`` characters including the ellipsis."""
    text = " ".join((text or "").split())
    if len(text) <= limit:
        return text
    cut = text[: limit - 3]
    if " " in cut:
        cut = cut[: cut.rfind(" ")]
    return cut.rstrip() + "..."


def citations(items: Iterable[Mapping[str, str | None]]) -> list[Citation]:
    """Items: ``title``, ``url`` and ``content`` (snippet). Order is the [n] numbering: the n-th item is ``[n]``."""
    return [
        Citation(content=clip(i.get("content") or i.get("title") or ""), title=i.get("title"), url=i.get("url"))
        for i in items
    ]
