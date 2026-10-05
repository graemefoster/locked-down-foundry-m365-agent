from __future__ import annotations

from aiohttp import ClientSession
from microsoft_agents.hosting.core import ClaimsIdentity, TurnContext
from microsoft_agents.hosting.core.connector import ConnectorClientBase
from microsoft_agents.hosting.core.connector.teams import TeamsConnectorClient
from microsoft_agents.hosting.core.rest_channel_service_client_factory import (
    RestChannelServiceClientFactory,
)


class EnvironmentAwareConnectorFactory(RestChannelServiceClientFactory):
    """Create Teams connector sessions that honor standard proxy variables."""

    async def create_connector_client(
        self,
        context: TurnContext | None,
        claims_identity: ClaimsIdentity,
        service_url: str,
        audience: str,
        scopes: list[str] | None = None,
        use_anonymous: bool = False,
    ) -> ConnectorClientBase:
        connector = await super().create_connector_client(
            context,
            claims_identity,
            service_url,
            audience,
            scopes,
            use_anonymous,
        )
        if not isinstance(connector, TeamsConnectorClient):
            return connector

        return await self._make_environment_aware(connector)

    @staticmethod
    async def _make_environment_aware(
        connector: TeamsConnectorClient,
    ) -> TeamsConnectorClient:
        session = ClientSession(
            base_url=connector.base_uri,
            headers=connector.client.headers.copy(),
            trust_env=True,
        )
        environment_aware_connector = TeamsConnectorClient(
            connector.base_uri,
            "",
            session=session,
        )
        await connector.close()
        return environment_aware_connector
