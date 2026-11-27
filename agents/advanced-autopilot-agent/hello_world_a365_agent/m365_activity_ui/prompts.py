"""Follow-up prompt buttons as ``Action.Execute`` (verb ``prompt``): works in Agents Playground and Teams.

Playground ignores ``Action.Submit`` + ``msteams.imBack``; ``Action.Execute`` arrives as an ``adaptiveCard/action``
invoke. ``PromptDesk.handle`` echoes ``You asked: ...`` and runs the prompt as a normal user turn through the
caller's ``run_prompt(context, prompt)``, inline (default) or after an ack on a proactive context.
"""
from __future__ import annotations

import asyncio
import inspect
import logging
import os
from typing import Any, Awaitable, Callable, Mapping

from microsoft_agents.activity import Activity, ActivityTypes, InvokeResponse

from .cards import PROMPT_VERB

logger = logging.getLogger(__name__)

INVOKE_NAME = "adaptiveCard/action"
RunPrompt = Callable[[Any, str], Awaitable[None] | None]


def _prompt_of(context: Any) -> str | None:
    """The prompt text if ``context`` is a ``prompt`` Action.Execute invoke, else ``None``."""
    activity = context.activity
    if getattr(activity, "name", None) != INVOKE_NAME:
        return None
    value = activity.value if isinstance(activity.value, Mapping) else getattr(activity.value, "model_dump", lambda **k: {})(mode="json")
    action = value.get("action") if isinstance(value, Mapping) else None
    if not isinstance(action, Mapping) or action.get("verb") != PROMPT_VERB:
        return None
    data = action.get("data")
    prompt = data.get("prompt") if isinstance(data, Mapping) else None
    return prompt.strip() if isinstance(prompt, str) and prompt.strip() else None


MODES = ("inline", "proactive")


class PromptDesk:
    """Handles ``prompt`` invokes. ``run_prompt(context, prompt)`` (sync or async) runs the turn, once per click.

    ``mode="inline"`` (default): echo and run the turn on the live invoke context, then return the 200. Works with no
    credentials (Playground, local); the click's 200 arrives only after the turn, and Teams times an invoke out after
    roughly 10 s, so use it for short turns.
    ``mode="proactive"``: return the 200 at once, then run the turn on a proactive context via
    ``adapter.continue_conversation(app_id, continuation_activity, callback)``. ``run_prompt`` receives that new
    context (the invoke context is closed after the ack). Needs app credentials; ``register(app)`` supplies the
    adapter, ``app_id`` is a parameter or the ``CLIENT_ID`` env var. Keep the desk alive for the app's lifetime."""

    def __init__(self, run_prompt: RunPrompt, *, echo: bool = True, mode: str = "inline",
                 adapter: Any = None, app_id: str | None = None) -> None:
        if mode not in MODES:
            raise ValueError(f"mode must be one of {MODES}, got {mode!r}")
        self.run_prompt = run_prompt
        self.echo = echo
        self.mode = mode
        self.adapter = adapter
        self.app_id = app_id
        self._tasks: set[asyncio.Task] = set()

    def matches(self, context: Any) -> bool:
        """Synchronous on purpose: hosting-core calls ``route.selector(context)`` without awaiting."""
        return _prompt_of(context) is not None

    async def handle(self, context: Any) -> InvokeResponse | None:
        """200 for a prompt invoke (after the turn in ``inline`` mode, before it in ``proactive``); ``None`` (not
        handled) for anything else. A ``prompt`` verb without prompt text gets a 400."""
        activity = context.activity
        if getattr(activity, "name", None) != INVOKE_NAME:
            return None
        prompt = _prompt_of(context)
        if prompt is None:
            value = activity.value if isinstance(activity.value, Mapping) else {}
            action = value.get("action") if isinstance(value, Mapping) else None
            if isinstance(action, Mapping) and action.get("verb") == PROMPT_VERB:
                return InvokeResponse(status=400, body={"statusCode": 400, "type": "application/vnd.microsoft.error",
                                                        "value": {"code": "BadRequest", "message": "missing prompt"}})
            return None
        ok = InvokeResponse(status=200, body={"statusCode": 200, "type": "application/vnd.microsoft.activity.message",
                                              "value": "OK"})
        if self.mode == "inline":
            await self._run(context, prompt)
            return ok
        app_id = self.app_id or os.getenv("CLIENT_ID") or ""
        if self.adapter is None or not app_id:
            raise RuntimeError("PromptDesk(mode='proactive') needs an adapter and app_id (or CLIENT_ID)")
        reference = activity.get_conversation_reference()
        continuation = reference.get_continuation_activity()
        task = asyncio.ensure_future(self._proactive(app_id, continuation, prompt))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return ok

    async def _proactive(self, app_id: str, continuation: Any, prompt: str) -> None:
        try:
            await self.adapter.continue_conversation(app_id, continuation, lambda ctx: self._run(ctx, prompt))
        except Exception:  # noqa: BLE001 - a background task has no caller to raise to
            logger.exception("PromptDesk proactive turn failed")

    async def _run(self, context: Any, prompt: str) -> None:
        if self.echo:
            await context.send_activity(f"You asked: {prompt}")
        result = self.run_prompt(context, prompt)
        if inspect.isawaitable(result):
            await result

    async def wait_idle(self) -> None:
        """Await running proactive turns (tests, shutdown)."""
        while self._tasks:
            await asyncio.gather(*list(self._tasks), return_exceptions=True)

    def register(self, app: Any) -> None:
        """Route only ``prompt`` invokes here (sync selector, highest rank) so ``ApprovalDesk`` keeps the other verbs.
        In proactive mode the app's adapter is used unless one was given."""
        from microsoft_agents.hosting.core.app._routes import RouteRank

        if self.mode == "proactive" and self.adapter is None:
            self.adapter = app.adapter

        async def _on_prompt(context: Any, state: Any) -> None:  # noqa: ANN401
            response = await self.handle(context)
            await context.send_activity(Activity(type=ActivityTypes.invoke_response, value=response))

        app.add_route(self.matches, _on_prompt, is_invoke=True, rank=RouteRank.FIRST)
