"""Rich turns for Activity Protocol agents in M365 Copilot and Teams 1:1."""
from .adapter import ResponsesAdapter, default_label, present_responses
from .approval import ApprovalDesk, CardInfo, approval_card, resolved_card
from .cards import ADAPTIVE_CARD_CONTENT_TYPE, adaptive_card, kpi_strip, prompt_actions, with_actions
from .charts import bar_chart, donut_chart, gauge_chart, horizontal_bar_chart, line_chart, pie_chart
from .citations import citations, clip
from .email import EmailBlock, approval_block, bar_table, email_reply, figures_table, parse_approval_reply, reply_top, sources_footnotes
from .feedback import FeedbackDesk, FeedbackRecord, enable_feedback, log_feedback
from .formatting import markdown_to_html
from .forms import FormDesk, form_card, submitted_card, validate as validate_form
from .people import people_card
from .progress import ProgressTracker, done_card, progress_card
from .tables import outlook_event_url, outlook_message_url, require_https, table_card, teams_chat_url
from .presenter import TurnPresenter
from .prompts import PromptDesk
from .ui_tools import UI_INSTRUCTIONS, UiToolkit, UiTurn
from .tool_cards import render_tool_card, tool_step_label

__all__ = ["ADAPTIVE_CARD_CONTENT_TYPE", "ApprovalDesk", "CardInfo", "EmailBlock", "approval_block", "bar_table", "email_reply", "figures_table", "parse_approval_reply", "reply_top", "sources_footnotes", "PromptDesk", "ResponsesAdapter", "TurnPresenter",
           "adaptive_card", "approval_card", "bar_chart", "citations", "clip", "default_label", "donut_chart",
           "kpi_strip", "markdown_to_html", "present_responses", "prompt_actions", "render_tool_card",
           "resolved_card", "gauge_chart", "horizontal_bar_chart", "line_chart", "pie_chart", "FeedbackDesk", "FeedbackRecord",
           "enable_feedback", "log_feedback", "FormDesk", "form_card", "submitted_card", "validate_form", "people_card",
           "ProgressTracker", "done_card", "progress_card", "outlook_event_url", "outlook_message_url", "require_https",
           "table_card", "teams_chat_url", "UI_INSTRUCTIONS", "UiToolkit", "UiTurn", "tool_step_label", "with_actions"]
