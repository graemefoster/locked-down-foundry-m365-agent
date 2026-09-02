# Publish a network-isolated Foundry agent to Microsoft 365 and Teams

This is a locked-down variant of the Microsoft Learn how-to
[Publish agents to Microsoft 365 and Teams by using the REST API](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/publish-copilot-virtual-network).
It explains how to make a Foundry agent reachable from Microsoft 365 Copilot and Teams while the
Foundry account keeps `publicNetworkAccess=Disabled`.

Microsoft 365 does not support private connectivity to agent endpoints: the Activity Protocol
route that Copilot and Teams call must be reachable over the public internet. There are two ways to
satisfy that requirement without ever enabling public network access on the Foundry account:

- **Approach A — scoped public Activity Protocol exception.** Foundry itself opens a
  service-managed, source-IP-filtered public path to *only* the Activity Protocol route, using the
  `enable_m365_public_endpoint` flag. This is the Learn article's default.
- **Approach B — bring your own front door.** Foundry exposes no public path at all. You stand up
  a public reverse proxy (for example Application Gateway in front of API Management) and point the
  agent's Activity Protocol endpoint at your proxy.

Foundry account networking is not changed by either approach. Do not enable public network access
on the Foundry account.

> Publishing to Microsoft 365 and Teams causes those services to process and store data associated
> with the agent (name, icon, description, and the agent's responses to user queries). Confirm the
> resulting data flows meet your compliance, data-residency, and governance requirements before you
> publish.

> **Autopilot agents no longer require an Azure Bot Service resource.** The classic REST flow
> created an `Microsoft.BotService` registration to proxy channel messages. Autopilot agents
> published through Microsoft Agent 365 register their Activity Protocol endpoint directly, so
> there is no separate Bot Service resource to create or maintain.

## Approach A — scoped public Activity Protocol exception (`enable_m365_public_endpoint`)

Foundry opens a narrow, source-IP-filtered public path to the Activity Protocol route only. The
Responses, Invocations, A2A, MCP, agent-management, and all other project APIs stay private.

Setting `enable_m365_public_endpoint: true` changes *network reachability*, not *authorization*.
Public reachability is not anonymous access: requests from non-Microsoft source ranges are dropped,
and allowed ranges must still pass Microsoft Entra / channel authentication.

```text
 Microsoft 365 Copilot / Teams
             │  activity protocol
             ▼
     ┌───────────────┐
     │ Public internet│
     └───────┬────────┘
             │  source-IP filtered + auth enforced by Foundry
             ▼
 ┌──────────────────────────────────────────────┐
 │ Foundry account  (publicNetworkAccess=Disabled)│
 │   scoped public exception: activityProtocol only│
 │   all other project APIs stay private          │
 │                 │                              │
 │                 ▼                              │
 │              Agent                             │
 └──────────────────────────────────────────────┘
```

Enable the flag in the agent's Activity Protocol configuration, and keep an authorization scheme so
Foundry can authenticate channel traffic:

```yaml
agent_endpoint:
  protocol_configuration:
    responses: {}
    activity:
      enable_m365_public_endpoint: true
  authorization_schemes:
    - type: Entra
    - type: BotServiceRbac
```

`activity` lets the channel adapters deliver messages. Source IP filtering is defense-in-depth; it
does not replace token validation, tenant checks, or RBAC.

> The endpoint update replaces `protocol_configuration` and `authorization_schemes` wholesale.
> Keep every protocol (for example `responses`) and scheme (for example `Entra`) you still need, or
> the endpoint loses them.

### Why some teams choose Approach B instead

`enable_m365_public_endpoint: true` is a Foundry-managed exception: it opens a public path on the
Foundry account itself, filtered to Microsoft source ranges. Some security teams do not want *any*
Foundry-hosted public exception on a resource they have deliberately set to
`publicNetworkAccess=Disabled` — they prefer all public ingress to terminate on infrastructure they
own, inspect, and control (WAF, logging, custom policy). Approach B keeps the flag `false` and
satisfies Microsoft 365's public-reachability requirement with a customer-owned front door.

## Approach B — bring your own front door

Keep `enable_m365_public_endpoint: false`. Foundry stays fully private. You put a public reverse
proxy in front of the Activity Protocol route and switch the agent's published endpoint to your
proxy. The proxy forwards to the private Foundry Activity Protocol route over a private connection.

A common, Cloud Adoption Framework–aligned shape is **Application Gateway (WAF, public IP) → API
Management → private Foundry endpoint**, but the front door could be Azure Front Door, a
third-party WAF/reverse proxy, or any service that can accept public traffic and reach the private
endpoint:

```text
 Microsoft 365 Copilot / Teams
             │  activity protocol
             │  (endpoint switched to your front door — see below)
             ▼
     ┌───────────────┐
     │ Public internet│
     └───────┬────────┘
             ▼
 ┌───────────────────────────┐
 │ Application Gateway (WAF)  │   your front door (Front Door / other proxy also work)
 │ public IP                 │
 └─────────────┬─────────────┘
               │  private
               ▼
 ┌───────────────────────────┐
 │ API Management            │   authN/Z, rate limiting, policy
 └─────────────┬─────────────┘
               │  private endpoint
               ▼
 ┌──────────────────────────────────────────────┐
 │ Foundry account (publicNetworkAccess=Disabled) │
 │   no public exception  (flag = false)          │
 │                 │                              │
 │                 ▼                              │
 │              Agent                             │
 └──────────────────────────────────────────────┘
```

The proxy targets the private Foundry Activity Protocol route:

```text
https://<resource-name>.services.ai.azure.com/api/projects/<project-name>/agents/<agent-name>/endpoint/protocols/activityProtocol?api-version=2025-05-15-preview
```

Because your front door reaches that route over a private connection, Foundry does not need
`enable_m365_public_endpoint`. The `activity` protocol and an authorization scheme must still be
present so the endpoint accepts activity messages.

Trade-off: Approach B keeps Foundry entirely private but adds one public hop that you own and must
secure (WAF, source-range restriction, token validation, deny-by-default policy), whereas
Approach A lets Foundry manage the source-IP-filtered exception for you.

### Switching the agent's endpoint to your front door

Autopilot agents resolve their Activity Protocol endpoint from the agent blueprint. To point the
agent at your front door instead of the default Foundry endpoint, edit the blueprint configuration
in the Teams developer portal:

```text
https://dev.teams.microsoft.com/tools/agent-blueprint/<blueprint-id>/configuration
```

Set the endpoint to your front door's public URL (for example the Application Gateway listener that
fronts APIM). Copilot and Teams then deliver activity messages to your proxy, which forwards them to
the private Foundry endpoint.

## Known behaviors during the current preview

Both approaches currently surface some transient errors that are expected while the feature is in
preview:

- **`500` identity errors** can appear shortly after publishing, before the agent's identity has
  fully propagated across Microsoft 365.
- **`502` Bad Gateway** entries can appear in your Foundry logs for the Activity Protocol / session
  routes during the same window.

These are expected right now and typically clear on their own as propagation completes. Treat them
as noise unless they persist well beyond initial publishing.

## Callout: it can take time for the agent to appear (both approaches)

> **After publishing, the agent can take a while — sometimes hours — to appear under your user
> identity in Microsoft 365 Copilot and Teams. This propagation lag is normal and is not a
> deployment or identity failure.**
>
> You can usually speed discovery up by:
>
> - **searching for the agent's full email address in Teams**, or
> - **sending the agent an email from Outlook.**
>
> Either action nudges the catalog to surface the agent for your identity sooner.

## Reference implementation

This repository is a working reference implementation of **Approach B**: a public edge in front of
private API Management, forwarding to a Foundry account that stays `publicNetworkAccess=Disabled`.
See [docs/architecture.md](architecture.md) for the concrete topology, identities, and Teams
routing.

## Upstream

- [Publish agents to Microsoft 365 and Teams by using the REST API](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/publish-copilot-virtual-network)
