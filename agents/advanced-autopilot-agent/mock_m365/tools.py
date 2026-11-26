"""Function-tool schemas (Responses API) + dispatcher over the generated mock fixture."""
from __future__ import annotations

import json
from typing import Any

from .generate import generate

_DATA: dict | None = None


def _data() -> dict:
    global _DATA
    if _DATA is None:
        _DATA = generate()
    return _DATA


def _fn(name: str, description: str, props: dict[str, Any]) -> dict[str, Any]:
    return {"type": "function", "name": name, "description": description,
            "parameters": {"type": "object", "properties": props, "additionalProperties": False}}


TOOL_SCHEMAS: list[dict[str, Any]] = [
    _fn("list_messages", "List inbox messages (newest first) with id, subject, sender, received time, importance, link.",
        {"top": {"type": "integer", "description": "max messages (default 30)"},
         "unread_only": {"type": "boolean"}}),
    _fn("get_message", "Get one inbox message in full, by id.", {"id": {"type": "string"}}),
    _fn("list_events", "List calendar events for today and tomorrow, with start/end, location, attendees, link.",
        {"day": {"type": "string", "enum": ["today", "tomorrow", "both"]}}),
]


def call_tool(name: str, arguments: str | dict | None) -> str:
    args = json.loads(arguments) if isinstance(arguments, str) and arguments else (arguments or {})
    d = _data()
    if name == "list_messages":
        msgs = [m for m in d["messages"] if not (args.get("unread_only") and m["isRead"])]
        keys = ("id", "subject", "from", "receivedDateTime", "importance", "isRead", "conversationId", "bodyPreview", "webLink")
        out = [{k: m[k] for k in keys} for m in msgs[: int(args.get("top") or 30)]]
        return json.dumps({"value": out})
    if name == "get_message":
        m = next((m for m in d["messages"] if m["id"] == args.get("id")), None)
        return json.dumps(m or {"error": f"message {args.get('id')} not found"})
    if name == "list_events":
        day = args.get("day") or "both"
        evs = d["events"]
        today = d["generated_for"]
        if day == "today":
            evs = [e for e in evs if e["start"].startswith(today)]
        elif day == "tomorrow":
            evs = [e for e in evs if not e["start"].startswith(today)]
        return json.dumps({"today": today, "value": evs})
    return json.dumps({"error": f"unknown tool {name}"})
