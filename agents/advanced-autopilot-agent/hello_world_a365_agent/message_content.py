from __future__ import annotations

from dataclasses import dataclass
from html.parser import HTMLParser
from typing import Any, Optional
from urllib.parse import unquote, urlparse


@dataclass(frozen=True)
class ImageReference:
    url: str
    content_type: str = ""
    alt_text: str = ""


@dataclass(frozen=True)
class ParsedMessage:
    text: str
    images: list[ImageReference]


class _TeamsMessageHtmlParser(HTMLParser):
    _BLOCK_TAGS = frozenset({"br", "div", "li", "p"})

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._text_parts: list[str] = []
        self.images: list[ImageReference] = []

    def handle_starttag(
        self,
        tag: str,
        attrs: list[tuple[str, Optional[str]]],
    ) -> None:
        normalized_tag = tag.lower()
        attributes = {name.lower(): value or "" for name, value in attrs}
        if normalized_tag in self._BLOCK_TAGS:
            self._text_parts.append("\n")
        if normalized_tag != "img" or not attributes.get("src"):
            return

        image_format = attributes.get("itemscope", "").lower()
        content_type = (
            f"image/{image_format}"
            if image_format in {"gif", "jpeg", "jpg", "png", "webp"}
            else ""
        )
        self.images.append(
            ImageReference(
                url=attributes["src"],
                content_type=content_type.replace("image/jpg", "image/jpeg"),
                alt_text=attributes.get("alt", ""),
            )
        )

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() in self._BLOCK_TAGS:
            self._text_parts.append("\n")

    def handle_data(self, data: str) -> None:
        self._text_parts.append(data)

    def parsed_message(self) -> ParsedMessage:
        lines = (
            " ".join(line.split())
            for line in "".join(self._text_parts).splitlines()
        )
        text = "\n".join(line for line in lines if line).strip()
        return ParsedMessage(text=text, images=self.images)


def parse_message(message: str) -> ParsedMessage:
    if "<" not in message or ">" not in message:
        return ParsedMessage(text=message.strip(), images=[])

    parser = _TeamsMessageHtmlParser()
    parser.feed(message)
    parser.close()
    return parser.parsed_message()


def merge_image_references(
    *groups: list[ImageReference],
) -> list[ImageReference]:
    unique: dict[str, ImageReference] = {}
    for group in groups:
        for image in group:
            unique.setdefault(_image_identity(image.url), image)
    return list(unique.values())


def _image_identity(url: str) -> str:
    segments = [
        unquote(segment)
        for segment in urlparse(url).path.split("/")
        if segment
    ]
    for marker in ("objects", "attachments"):
        if marker in segments:
            marker_index = segments.index(marker)
            if marker_index + 1 < len(segments):
                return f"attachment:{segments[marker_index + 1]}"
    return url


def parse_attachment_location(
    url: str,
    trusted_service_url: str = "",
) -> Optional[tuple[str, str]]:
    parsed = urlparse(url)
    hostname = parsed.hostname or ""
    trusted_service = urlparse(trusted_service_url)
    is_trusted_service = (
        trusted_service.scheme == "https"
        and parsed.scheme == trusted_service.scheme
        and parsed.hostname == trusted_service.hostname
        and parsed.port == trusted_service.port
    )
    is_skype_image_host = (
        hostname == "asm.skype.com" or hostname.endswith(".asm.skype.com")
    )
    if parsed.scheme != "https" or not (
        is_trusted_service or is_skype_image_host
    ):
        return None

    segments = [unquote(segment) for segment in parsed.path.split("/") if segment]
    for marker in ("objects", "attachments"):
        if marker not in segments:
            continue
        marker_index = segments.index(marker)
        try:
            views_index = segments.index("views", marker_index + 2)
            return segments[marker_index + 1], segments[views_index + 1]
        except (IndexError, ValueError):
            return None
    return None


def detect_image_content_type(image_bytes: bytes) -> str:
    if image_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if image_bytes.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if image_bytes.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if (
        len(image_bytes) >= 12
        and image_bytes.startswith(b"RIFF")
        and image_bytes[8:12] == b"WEBP"
    ):
        return "image/webp"
    return ""


def build_multimodal_input(
    message: str,
    image_data_urls: list[str],
) -> str | list[dict[str, Any]]:
    if not image_data_urls:
        return message

    content: list[dict[str, Any]] = [
        {
            "type": "input_text",
            "text": message or "Describe the attached image.",
        }
    ]
    content.extend(
        {
            "type": "input_image",
            "image_url": image_url,
            "detail": "auto",
        }
        for image_url in image_data_urls
    )
    return [{"role": "user", "content": content}]
