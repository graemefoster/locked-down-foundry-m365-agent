"""Rich turns for Activity Protocol agents in M365 Copilot and Teams 1:1."""
from .adapter import ResponsesAdapter, default_label, present_responses
from .approval import ApprovalDesk, CardInfo, approval_card, resolved_card
from .cards import ADAPTIVE_CARD_CONTENT_TYPE, adaptive_card, kpi_strip, prompt_actions, with_actions
from .charts import bar_chart, donut_chart
from .citations import citations, clip
from .email import EmailBlock, approval_block, bar_table, email_reply, figures_table, parse_approval_reply, reply_top, sources_footnotes
from .formatting import markdown_to_html
from .presenter import TurnPresenter
from .prompts import PromptDesk
from .ui_tools import UI_INSTRUCTIONS, UiToolkit, UiTurn
from .tool_cards import render_tool_card, tool_step_label

__all__ = ["ADAPTIVE_CARD_CONTENT_TYPE", "ApprovalDesk", "CardInfo", "EmailBlock", "approval_block", "bar_table", "email_reply", "figures_table", "parse_approval_reply", "reply_top", "sources_footnotes", "PromptDesk", "ResponsesAdapter", "TurnPresenter",
           "adaptive_card", "approval_card", "bar_chart", "citations", "clip", "default_label", "donut_chart",
           "kpi_strip", "markdown_to_html", "present_responses", "prompt_actions", "render_tool_card",
           "resolved_card", "UI_INSTRUCTIONS", "UiToolkit", "UiTurn", "tool_step_label", "with_actions"]
