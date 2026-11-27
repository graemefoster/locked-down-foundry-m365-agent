"""Teams thumbs up/down on AI answers (Agents SDK 1.7.0).

``enable_feedback(activity)`` sets ``channelData.feedbackLoop = {"type": "default"}`` (Teams SDK ``FeedbackLoop``:
https://learn.microsoft.com/en-us/python/api/microsoft-teams-api/microsoft_teams.api.feedbackloop and
https://learn.microsoft.com/en-us/microsoft-365/agents-sdk/teams/teams-feedback); ``type="custom"`` makes Teams
fire a task-module fetch instead. A click arrives as a ``message/submitAction`` invoke whose value is
``{actionName: "feedback", actionValue: {reaction: "like"|"dislike", feedback: "<json {feedbackText}>"}}`` with
``replyToId`` = the rated message (https://learn.microsoft.com/en-us/microsoftteams/platform/agents-in-teams/integrate-ai/user-feedback-controls).
Call it on the final message only. Verified against docs and unit tests; not in a live Teams client.
"""
from __future__ import annotations

import inspect
import json
import logging
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Mapping

from microsoft_agents.activity import Activity, ActivityTypes, InvokeResponse

logger = logging.getLogger(__name__)

INVOKE_NAME = "message/submitAction"
ACTION_NAME = "feedback"
REACTIONS = ("like", "dislike")


@dataclass(frozen=True)
class FeedbackRecord:
    reaction: str  # "like" | "dislike"
    text: str  # free-text comment, "" when none
    reply_to_id: str | None  # id of the rated message
    conversation_id: str | None = None
    user_id: str | None = None


FeedbackHandler = Callable[[FeedbackRecord], Awaitable[None] | None]


def enable_feedback(activity: Any, *, loop_type: str = "default") -> Any:
    """Mark an outgoing message activity (``Activity`` or dict) so Teams shows thumbs up/down. Returns it."""
    if loop_type not in ("default", "custom"):
        raise ValueError("loop_type must be 'default' or 'custom'")
    if isinstance(activity, dict):
        data = activity.setdefault("channelData", {})
        data["feedbackLoop"] = {"type": loop_type}
        return activity
    data = dict(activity.channel_data) if isinstance(activity.channel_data, Mapping) else {}
    data["feedbackLoop"] = {"type": loop_type}
    activity.channel_data = data
    return activity


def log_feedback(record: FeedbackRecord) -> None:
    """Default sink: one structured log line."""
    logger.info("feedback %s", json.dumps({"reaction": record.reaction, "text": record.text,
                                           "reply_to_id": record.reply_to_id,
                                           "conversation_id": record.conversation_id, "user_id": record.user_id}))


def _value_of(activity: Any) -> Mapping | None:
    v = getattr(activity, "value", None)
    if not isinstance(v, Mapping):
        v = getattr(v, "model_dump", lambda **k: None)(mode="json", by_alias=True)
    return v if isinstance(v, Mapping) else None


def _parse(activity: Any) -> FeedbackRecord | None:
    if getattr(activity, "name", None) != INVOKE_NAME:
        return None
    value = _value_of(activity)
    if not value:
        return None
    name = value.get("actionName") or value.get("action_name")
    if name != ACTION_NAME:
        return None
    av = value.get("actionValue") or value.get("action_value")
    if not isinstance(av, Mapping):
        return None
    reaction = av.get("reaction")
    if reaction not in REACTIONS:
        return None
    raw = av.get("feedback")
    text = ""
    if isinstance(raw, str) and raw:
        try:
            parsed = json.loads(raw)
            text = str(parsed.get("feedbackText", "")) if isinstance(parsed, Mapping) else raw
        except ValueError:
            text = raw
    elif isinstance(raw, Mapping):
        text = str(raw.get("feedbackText", ""))
    conv = getattr(activity, "conversation", None)
    sender = getattr(activity, "from_property", None)
    return FeedbackRecord(reaction=reaction, text=text, reply_to_id=getattr(activity, "reply_to_id", None),
                          conversation_id=getattr(conv, "id", None), user_id=getattr(sender, "id", None))


class FeedbackDesk:
    """Handles feedback invokes; ``on_feedback(record)`` (sync or async) defaults to a log line."""

    def __init__(self, on_feedback: FeedbackHandler = log_feedback) -> None:
        self.on_feedback = on_feedback

    def matches(self, context: Any) -> bool:
        """Synchronous on purpose: hosting-core calls ``route.selector(context)`` without awaiting."""
        return _parse(context.activity) is not None

    async def handle(self, context: Any) -> InvokeResponse | None:
        """200 after the handler ran; ``None`` for anything that is not a feedback invoke."""
        record = _parse(context.activity)
        if record is None:
            return None
        result = self.on_feedback(record)
        if inspect.isawaitable(result):
            await result
        return InvokeResponse(status=200)

    def register(self, app: Any) -> None:
        """Route only feedback invokes here (sync selector, highest rank)."""
        from microsoft_agents.hosting.core.app._routes import RouteRank

        async def _on_feedback(context: Any, state: Any) -> None:  # noqa: ANN401
            response = await self.handle(context)
            await context.send_activity(Activity(type=ActivityTypes.invoke_response, value=response))

        app.add_route(self.matches, _on_feedback, is_invoke=True, rank=RouteRank.FIRST)
