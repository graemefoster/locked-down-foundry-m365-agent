from __future__ import annotations

import unittest

from microsoft_agents.hosting.core.connector.teams import TeamsConnectorClient

from hello_world_a365_agent.environment_aware_connector import (
    EnvironmentAwareConnectorFactory,
)


class _StubEnvironmentAwareConnectorFactory(EnvironmentAwareConnectorFactory):
    def __init__(self, connector: TeamsConnectorClient) -> None:
        self._connector = connector

    async def _create_sdk_connector(self) -> TeamsConnectorClient:
        return self._connector

    async def create_connector_client(
        self,
        context,
        claims_identity,
        service_url,
        audience,
        scopes=None,
        use_anonymous=False,
    ):
        connector = await self._create_sdk_connector()
        return await self._make_environment_aware(connector)


class EnvironmentAwareConnectorTests(unittest.IsolatedAsyncioTestCase):
    async def test_preserves_auth_and_enables_environment_proxy(self) -> None:
        original = TeamsConnectorClient(
            "https://smba.trafficmanager.net/amer/tenant/",
            "secret-token",
        )
        factory = _StubEnvironmentAwareConnectorFactory(original)

        connector = await factory.create_connector_client(
            None,
            None,
            "https://smba.trafficmanager.net/amer/tenant/",
            "audience",
        )

        try:
            self.assertTrue(connector.client.trust_env)
            self.assertEqual(
                "Bearer secret-token",
                connector.client.headers["Authorization"],
            )
            self.assertTrue(original.client.closed)
        finally:
            await connector.close()
