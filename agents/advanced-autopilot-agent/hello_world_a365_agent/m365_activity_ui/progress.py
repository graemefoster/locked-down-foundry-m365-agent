"""Live progress card: one Adaptive Card sent early, updated in place as steps complete.

Agentic Teams/Copilot traffic is never streamed, so the user otherwise sees typing, then one message. A
``ProgressTracker`` sends a card at once and edits it with ``turn_context.update_activity`` (same activity id).
If the channel refuses an update, updating stops silently; progress is cosmetic and never fails the turn.

    tracker = ProgressTracker(ctx, "Checking inbox…")
    await tracker.start()
    tracker.step("Reading mail")        # sync, safe from TurnPresenter-style callbacks; marks the previous step done
    ...
    await tracker.finish()              # compact "Done in 8 s · 3 steps" card (or delete with delete_on_done=True)

Drive from a presenter without editing it: ``tracker.wrap(presenter)`` makes ``presenter.step`` also advance
the tracker. ``ProgressBar`` is not in the bundled AC schema nor guaranteed on every host, so it carries a
text-bar ``fallback`` element; pass ``progress_bar=False`` for a text-only bar.
"""
from __future__ import annotations

import asyncio
import time
from typing import Any, Callable

from microsoft_agents.activity import Activity, Attachment

from .cards import ADAPTIVE_CARD_CONTENT_TYPE, adaptive_card

ICONS = {"pending": "⚪", "running": "⏳", "done": "✅", "failed": "❌"}
_BAR_CELLS = 10


def _text_bar(fraction: float) -> str:
    n = round(fraction * _BAR_CELLS)
    return "▰" * n + "▱" * (_BAR_CELLS - n)


def progress_card(title: str, steps: list[tuple[str, str]], *, progress_bar: bool = True) -> dict[str, Any]:
    """Card for ``steps`` = [(label, state)] with state pending|running|done|failed."""
    finished = sum(1 for _, s in steps if s in ("done", "failed"))
    fraction = finished / len(steps) if steps else 0.0
    body: list[dict[str, Any]] = [{"type": "TextBlock", "text": title, "weight": "Bolder", "wrap": True}]
    text_bar = {"type": "TextBlock", "text": f"{_text_bar(fraction)} {round(fraction * 100)}%",
                "spacing": "Small", "wrap": True}
    if progress_bar:
        body.append({"type": "ProgressBar", "value": round(fraction, 2), "max": 1, "fallback": text_bar})
    else:
        body.append(text_bar)
    for label, state in steps:
        body.append({"type": "TextBlock", "text": f"{ICONS.get(state, ICONS['pending'])} {label}",
                     "spacing": "None", "wrap": True, "isSubtle": state == "pending"})
    return adaptive_card(body)


def done_card(seconds: float, steps: int) -> dict[str, Any]:
    """Compact final state."""
    noun = "step" if steps == 1 else "steps"
    return adaptive_card([{"type": "TextBlock", "text": f"✅ Done in {round(seconds)} s · {steps} {noun}",
                           "isSubtle": True, "size": "Small", "wrap": True}])


class ProgressTracker:
    """Send-then-update progress card. All Teams I/O is serialised and errors are swallowed.

    ``steps`` pre-declares the plan (shown pending); ``step(label)`` completes the running step and runs
    ``label`` (appended if not declared). ``delete_on_done`` removes the card in ``finish`` instead of collapsing it.
    """

    def __init__(self, context: Any, title: str = "Working on it…", steps: list[str] | None = None, *,
                 delete_on_done: bool = False, progress_bar: bool = True,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self._ctx = context
        self._title = title
        self._steps: list[list[str]] = [[s, "pending"] for s in (steps or [])]
        self._delete = delete_on_done
        self._bar = progress_bar
        self._clock = clock
        self._t0 = clock()
        self._id: str | None = None
        self._broken = False  # a send/update failed: stop touching the channel
        self._finished = False
        self._chain: asyncio.Future | None = None

    @property
    def active(self) -> bool:
        """True while the card is live (sent and no channel error yet)."""
        return self._id is not None and not self._broken

    def _activity(self, card: dict[str, Any]) -> Activity:
        return Activity(type="message", attachments=[Attachment(content_type=ADAPTIVE_CARD_CONTENT_TYPE, content=card)])

    def _card(self) -> dict[str, Any]:
        return progress_card(self._title, [(s, st) for s, st in self._steps], progress_bar=self._bar)

    async def start(self) -> None:
        """Send the card now. A send failure disables progress for the turn."""
        if self._id is not None or self._broken:
            return
        try:
            res = await self._ctx.send_activity(self._activity(self._card()))
            self._id = getattr(res, "id", None)
        except Exception:
            self._broken = True
            return
        if not self._id:
            self._broken = True

    async def _push(self, card: dict[str, Any]) -> None:
        if not self.active:
            return
        act = self._activity(card)
        act.id = self._id
        try:
            await self._ctx.update_activity(act)
        except Exception:
            self._broken = True

    def _advance(self, label: str | None, state_of_current: str = "done") -> None:
        for s in self._steps:
            if s[1] == "running":
                s[1] = state_of_current
        if label is not None:
            for s in self._steps:
                if s[0] == label and s[1] == "pending":
                    s[1] = "running"
                    return
            self._steps.append([label, "running"])

    async def astep(self, label: str) -> None:
        """Async form of ``step``: complete the running step, start ``label``, update the card."""
        if self._finished:
            return
        self._advance(label)
        await self._push(self._card())

    def step(self, label: str) -> None:
        """Sync form (needs a running loop): state changes now, the card update is queued in order."""
        if self._finished:
            return
        self._advance(label)
        self._queue(self._card())

    def _queue(self, card: dict[str, Any]) -> None:
        prev = self._chain

        async def run() -> None:
            if prev is not None:
                await asyncio.shield(prev)
            await self._push(card)

        self._chain = asyncio.ensure_future(run())

    def wrap(self, presenter: Any) -> Any:
        """Make ``presenter.step(label)`` also advance this tracker (instance-level; presenter.py is untouched)."""
        original = presenter.step

        def step(label: str) -> None:
            original(label)
            self.step(label)

        presenter.step = step
        return presenter

    async def finish(self, *, failed: bool = False) -> None:
        """Complete the running step, drain queued updates, then collapse or delete the card. Idempotent."""
        if self._finished:
            return
        self._finished = True
        if self._chain is not None:
            await self._chain
        self._advance(None, "failed" if failed else "done")
        if not self.active:
            return
        if self._delete:
            try:
                await self._ctx.delete_activity(self._id)
            except Exception:
                self._broken = True
            return
        await self._push(done_card(self._clock() - self._t0, len(self._steps)))

    async def __aenter__(self) -> "ProgressTracker":
        await self.start()
        return self

    async def __aexit__(self, exc_type, exc, tb) -> bool:
        await self.finish(failed=exc is not None)
        return False
