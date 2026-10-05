from __future__ import annotations

import unittest
from io import BytesIO
from types import SimpleNamespace

from hello_world_a365_agent.agent import FoundryDigitalWorkerAgent
from hello_world_a365_agent.message_content import (
    ImageReference,
    build_multimodal_input,
    parse_attachment_location,
    parse_message,
)


class _FakeAttachments:
    def __init__(self, content: bytes) -> None:
        self._content = content
        self.requests: list[tuple[str, str]] = []

    async def get_attachment(self, attachment_id: str, view_id: str) -> BytesIO:
        self.requests.append((attachment_id, view_id))
        return BytesIO(self._content)

    async def get_attachment_info(self, attachment_id: str):
        raise NotImplementedError


class _FakeConnector:
    def __init__(self, content: bytes) -> None:
        self._attachments = _FakeAttachments(content)

    @property
    def base_uri(self) -> str:
        return "https://example.invalid/"

    @property
    def attachments(self) -> _FakeAttachments:
        return self._attachments

    @property
    def conversations(self):
        return None

    async def close(self) -> None:
        return None


class AgentMessageContentTests(unittest.IsolatedAsyncioTestCase):
    def test_parses_teams_html_text_and_image(self) -> None:
        message = (
            '<p>What do you see?</p>\r\n'
            '<p><img src="https://us-api.asm.skype.com/v1/objects/'
            '0-wus-image/views/imgo" itemscope="png" alt="image"></p>'
        )

        parsed = parse_message(message)

        self.assertEqual("What do you see?", parsed.text)
        self.assertEqual(1, len(parsed.images))
        self.assertEqual("image/png", parsed.images[0].content_type)
        self.assertEqual("image", parsed.images[0].alt_text)

    def test_parses_supported_teams_attachment_location(self) -> None:
        location = parse_attachment_location(
            "https://us-api.asm.skype.com/v1/objects/0-wus-image/views/imgo"
        )

        self.assertEqual(("0-wus-image", "imgo"), location)

    def test_parses_attachment_from_authenticated_service_origin(self) -> None:
        service_url = (
            "https://smba.trafficmanager.net/amer/"
            "4b5f3023-3641-4fd5-9aa3-170596dd4367"
        )
        content_url = (
            f"{service_url}/v3/attachments/0-wus-image/views/original"
        )

        location = parse_attachment_location(
            content_url,
            trusted_service_url=service_url,
        )

        self.assertEqual(("0-wus-image", "original"), location)

    def test_rejects_untrusted_image_host(self) -> None:
        location = parse_attachment_location(
            "https://example.com/v1/objects/image/views/original"
        )

        self.assertIsNone(location)

    async def test_downloads_image_through_authenticated_connector(self) -> None:
        png = b"\x89PNG\r\n\x1a\nimage-data"
        connector = _FakeConnector(png)
        context = SimpleNamespace(
            turn_state={"ConnectorClient": connector},
            activity=SimpleNamespace(attachments=[]),
        )
        image = ImageReference(
            url="https://us-api.asm.skype.com/v1/objects/0-wus-image/views/imgo"
        )
        agent = object.__new__(FoundryDigitalWorkerAgent)

        images = await agent._download_message_images([image], context)

        self.assertEqual([("0-wus-image", "imgo")], connector.attachments.requests)
        self.assertEqual(
            "data:image/png;base64,iVBORw0KGgppbWFnZS1kYXRh",
            images[0],
        )

    def test_collects_html_and_image_attachments(self) -> None:
        service_url = "https://smba.trafficmanager.net/amer/tenant"
        context = SimpleNamespace(
            activity=SimpleNamespace(
                attachments=[
                    SimpleNamespace(
                        content_type="image/*",
                        content_url=(
                            f"{service_url}/v3/attachments/"
                            "0-wus-image/views/original"
                        ),
                        content=None,
                        name=None,
                    ),
                    SimpleNamespace(
                        content_type="text/html",
                        content_url=None,
                        content=(
                            '<p>What do you see?</p><p><img '
                            'src="https://us-api.asm.skype.com/v1/objects/'
                            '0-wus-image/views/imgo" itemscope="png"></p>'
                        ),
                        name=None,
                    ),
                ]
            )
        )
        agent = object.__new__(FoundryDigitalWorkerAgent)

        parsed = agent._collect_message_content("", context)

        self.assertEqual("What do you see?", parsed.text)
        self.assertEqual(1, len(parsed.images))
        self.assertIn("/v3/attachments/", parsed.images[0].url)

    def test_builds_multimodal_responses_input(self) -> None:
        response_input = build_multimodal_input(
            "What do you see?",
            ["data:image/png;base64,aW1hZ2U="],
        )

        self.assertEqual(
            [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "input_text",
                            "text": "What do you see?",
                        },
                        {
                            "type": "input_image",
                            "image_url": "data:image/png;base64,aW1hZ2U=",
                            "detail": "auto",
                        },
                    ],
                }
            ],
            response_input,
        )

if __name__ == "__main__":
    unittest.main()
