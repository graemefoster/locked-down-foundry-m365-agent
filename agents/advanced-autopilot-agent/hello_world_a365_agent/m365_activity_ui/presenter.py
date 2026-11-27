"""Turn presenter over the SDK ``context.streaming_response``: steps, text, cards, citations, one final message."""
from __future__ import annotations

import re
from typing import Any, Callable, Iterable, Mapping

from microsoft_agents.activity import Activity, Attachment
from microsoft_agents.hosting.core.app.streaming import Citation

from .cards import ADAPTIVE_CARD_CONTENT_TYPE, prompt_actions, with_actions
from .formatting import markdown_to_html

INFORMATIVE_LIMIT = 1000  # Teams rejects longer informative text
MIN_FIRST_CHUNK = 40  # chars of real text before the first streamed chunk
MAX_CITATIONS = 10  # Teams/Playground reject more references on one message (400 seen at 20)


class TurnPresenter:
    """One rich turn. Call ``step`` / ``text`` / ``add_card`` / ``add_citations`` as the agent works, then
    ``await finish()`` exactly once (or use ``async with``; an exception inside finishes with the error text).

    Surfaces: streaming channels (Teams 1:1, M365 Copilot) get informative updates and text chunks; other
    channels, and agentic requests (the SDK never streams them), get one final message; email gets one HTML
    message (HTML only there, markdown everywhere else). Teams allows about one update per second; the SDK
    queue already spaces sends by that interval, so labels are never dropped, only delayed.
    """

    def __init__(self, context: Any, *, ai_label: bool = True, feedback_loop: bool = True,
                 max_citations: int = MAX_CITATIONS, prompt_mode: str = "execute") -> None:
        self._ctx = context
        self._sr = context.streaming_response
        self._attachments: list[Attachment] = []
        self._citations: list[Citation] = []
        self._prompts: list[str] = []
        self._text = ""
        self._finished = False
        self._ai_label = ai_label
        self._feedback = feedback_loop
        self._max_citations = max_citations
        self._prompt_mode = prompt_mode
        self._before_finish: list[Callable[[], None]] = []
        self._email_blocks: list[Any] = []  # EmailBlock values, appended to the email body
        self._pending = ""  # text held back until the first chunk is worth sending
        self._started = False

    @property
    def surface(self) -> str:
        """``email`` or ``chat``; decides markdown vs HTML."""
        cid = self._ctx.activity.channel_id
        return "email" if cid and str(getattr(cid, "channel", cid)).lower() == "email" else "chat"

    @property
    def streaming(self) -> bool:
        return self.surface == "chat" and bool(self._sr.is_streaming_channel)

    def step(self, label: str) -> None:
        """Progress line (informative update). A no-op on non-streaming channels."""
        if self.surface == "chat":
            self._sr.queue_informative_update(label[:INFORMATIVE_LIMIT])

    def text(self, delta: str) -> None:
        self._text += delta
        if self.surface != "chat":
            return
        if self._started:
            self._sr.queue_text_chunk(delta)
            return
        self._pending += delta
        if self._first_chunk_ready(self._pending):
            self._flush()

    @staticmethod
    def _first_chunk_ready(buf: str) -> bool:
        """Enough real text: >= MIN_FIRST_CHUNK non-blank chars, or a finished line holding a letter/digit
        (so a lone ``##`` or whitespace is never the first chunk)."""
        if len(buf.strip()) >= MIN_FIRST_CHUNK:
            return True
        return bool(re.search(r"[^\W_][^\n]*\n", buf))

    def _flush(self) -> None:
        if self._pending:
            self._started = True
            self._sr.queue_text_chunk(self._pending)
            self._pending = ""

    def add_card(self, card: Mapping[str, Any]) -> None:
        """Attach an Adaptive Card dict; sent with the final message only."""
        self._attachments.append(Attachment(content_type=ADAPTIVE_CARD_CONTENT_TYPE, content=dict(card)))

    def before_finish(self, fn: Callable[[], None]) -> None:
        """Run ``fn`` once at the start of ``finish`` (e.g. to queue cards that must go on the final message)."""
        self._before_finish.append(fn)

    def add_email_block(self, block: Any) -> None:
        """Attach an email-safe ``EmailBlock`` (``.html``); rendered after the text on email turns only."""
        self._email_blocks.append(block)

    def add_citations(self, items: Iterable[Citation]) -> None:
        """Numbered in call order; the text must contain ``[n]`` for a citation to show (see ``finish``).
        Only the first ``max_citations`` (default 10) are sent, so positions 1..cap still match the text."""
        self._citations.extend(items)

    def suggest(self, prompts: Iterable[str]) -> None:
        """Suggested prompts. Teams hides suggestedActions on messages with attachments, so with a card they
        become imBack actions on the last card; without one they stay suggestedActions on a short follow-up."""
        self._prompts = list(prompts)

    async def finish(self) -> None:
        if self._finished:
            raise RuntimeError("TurnPresenter.finish() already called")
        self._finished = True
        for fn in self._before_finish:
            fn()
        if self.surface == "email":
            await self._finish_email()
            return
        sr = self._sr
        if re.search(r"[^\W_]", self._pending):  # markup/whitespace-only remainder is never sent
            self._flush()
        cites = self._citations[: self._max_citations]
        if cites:
            sr.set_citations(cites)
            if not any(f"[{n}]" in sr.get_message() for n in range(1, len(cites) + 1)):
                sr.queue_text_chunk("\n\nSources: " + " ".join(f"[{n}]" for n in range(1, len(cites) + 1)))
        if self._prompts and self._attachments:
            last = self._attachments[-1]
            last.content = with_actions(last.content, prompt_actions(self._prompts, self._prompt_mode))
        for a in self._attachments:
            sr.add_attachment(a)
        sr.set_generated_by_ai_label(self._ai_label)
        sr.set_feedback_loop(self._feedback)
        await sr.end_stream()
        if self._prompts and not self._attachments:
            await self._ctx.send_activity(Activity(
                type="message", text="Try next:",
                suggested_actions={"actions": [{"type": "imBack", "title": p[:100], "value": p} for p in self._prompts]},
            ))

    async def _finish_email(self) -> None:
        body = markdown_to_html(self._text or "")
        if self._citations:
            body += "<ol>" + "".join(
                f'<li><a href="{c.url}">{c.title or c.url}</a></li>' if c.url else f"<li>{c.title or ''}</li>"
                for c in self._citations) + "</ol>"
        body += "".join(b.html for b in self._email_blocks)
        await self._ctx.send_activity(Activity(
            type="message", text=f"<html><body>{body}</body></html>", attachments=self._attachments))

    async def __aenter__(self) -> "TurnPresenter":
        return self

    async def __aexit__(self, exc_type, exc, tb) -> bool:
        if not self._finished:
            if exc is not None:
                self.text(f"\n\nSorry, this turn failed: {type(exc).__name__}.")
            await self.finish()
        return False
