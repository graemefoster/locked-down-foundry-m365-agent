from __future__ import annotations

import base64
import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import Mock, patch

from hello_world_a365_agent.agent import FoundryDigitalWorkerAgent


class LocalAuthTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.agent = object.__new__(FoundryDigitalWorkerAgent)
        self.agent._instance_client_id = None

    def test_deployed_identity_takes_precedence(self) -> None:
        self.agent._instance_client_id = "agent-client"
        with patch.dict(os.environ, {"FOUNDRY_SUBSCRIPTION_ID": "local-sub"}):
            with patch("hello_world_a365_agent.agent.ManagedIdentityCredential") as credential:
                self.assertIs(self.agent._build_credential(), credential.return_value)
                credential.assert_called_once_with(client_id="agent-client")

    def test_local_subscription_selection(self) -> None:
        with patch.dict(os.environ, {"FOUNDRY_SUBSCRIPTION_ID": "local-sub"}, clear=True):
            with patch("hello_world_a365_agent.agent.AzureCliCredential") as credential:
                self.agent._build_credential()
                credential.assert_called_once_with(subscription="local-sub")

    def test_local_tenant_selection(self) -> None:
        with patch.dict(os.environ, {"FOUNDRY_TENANT_ID": "local-tenant"}, clear=True):
            with patch("hello_world_a365_agent.agent.AzureCliCredential") as credential:
                self.agent._build_credential()
                credential.assert_called_once_with(tenant_id="local-tenant")

    async def test_local_mcp_token(self) -> None:
        with patch.dict(os.environ, {"BEARER_TOKEN": "test-only-token"}):
            token = await self.agent._acquire_mcp_token(None, None, None, scope="scope")
            self.assertEqual("test-only-token", token)

    async def test_developer_token_rejected_with_agent_identity(self) -> None:
        self.agent._instance_client_id = "agent-client"
        with patch.dict(os.environ, {"BEARER_TOKEN": "test-only-token"}):
            with self.assertRaisesRegex(RuntimeError, "local development"):
                await self.agent._acquire_mcp_token(None, None, None, scope="scope")

    def test_helper_missing_scopes_fails_without_printing_token(self) -> None:
        script = Path(__file__).resolve().parents[4] / "scripts/get-mcp-dev-token.py"
        spec = importlib.util.spec_from_file_location("mcp_dev_token", script)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        payload = base64.urlsafe_b64encode(json.dumps({"scp": "other"}).encode()).decode()
        client = Mock()
        client.get_accounts.return_value = []
        client.acquire_token_interactive.return_value = {
            "access_token": f"header.{payload}.signature"
        }
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(helper.Path, "home", return_value=Path(directory)):
                with patch.object(helper, "scopes_by_audience", return_value={"aud": ["aud/required"]}):
                    with patch.object(helper.msal, "PublicClientApplication", return_value=client):
                        with patch("sys.argv", ["helper", "--client-id", "app", "--manifest", "unused"]):
                            stdout, stderr = io.StringIO(), io.StringIO()
                            with redirect_stdout(stdout), redirect_stderr(stderr):
                                self.assertEqual(1, helper.main())
                            self.assertEqual("", stdout.getvalue())
                            self.assertIn("MISSING", stderr.getvalue())
