"""Per-surface output format: markdown for chat surfaces, HTML only for email."""
from __future__ import annotations

import html
import re


def markdown_to_html(text: str) -> str:
    """Minimal, escaping markdown subset (paragraphs, bullets, bold, italics, links) for the email surface."""
    def inline(s: str) -> str:
        s = html.escape(s)
        s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"(?<!\*)\*(?!\s)(.+?)(?<!\s)\*(?!\*)", r"<em>\1</em>", s)
        return re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', s)

    out: list[str] = []
    bullets: list[str] = []

    def flush() -> None:
        if bullets:
            out.append("<ul>" + "".join(f"<li>{b}</li>" for b in bullets) + "</ul>")
            bullets.clear()

    for block in re.split(r"\n\s*\n", text.strip()):
        lines = block.splitlines()
        if all(re.match(r"\s*[-*] ", ln) for ln in lines):
            bullets.extend(inline(re.sub(r"^\s*[-*] ", "", ln)) for ln in lines)
            flush()
        else:
            out.append("<p>" + "<br>".join(inline(ln) for ln in lines) + "</p>")
    return "".join(out)
