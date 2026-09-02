# Architecture

This repository deploys one network-isolated Azure AI Foundry environment. Infrastructure and
application code are deployed with `azd`; private data-plane operations run in GitHub Actions
on the in-VNet self-hosted runner.

## Topology

```text
Operator workstation
  ├─ azd / Azure CLI ──> Azure Resource Manager
  └─ GitHub CLI ───────> repository variables and workflow dispatch

GitHub Actions
  └─ trusted-only self-hosted Linux runner in the Foundry spoke
       ├─ private Foundry endpoint
       ├─ private APIM endpoint
       ├─ private Key Vault and ACR endpoints
       └─ Azure control plane through managed identity

Teams / Microsoft 365
  └─ Bot Connector
       └─ public YARP App Service, restricted to Microsoft Teams source ranges
            └─ private APIM Teams API
                 └─ private Foundry activity protocol endpoint

Web or OBO caller
  └─ public YARP App Service
       └─ private APIM Foundry Agents API
            └─ private Foundry agent endpoint
```

The network is divided into a hub and workload spokes:

| Network area | Purpose |
|---|---|
| Hub | Azure Firewall and private DNS resolution. |
| Foundry spoke | Foundry agent subnet, private endpoints, Linux runner, and optional Windows dev VM. |
| App Service spoke | Outbound VNet integration for the YARP edge. |
| APIM spoke | APIM outbound VNet integration, APIM private endpoint, and provider Foundry private endpoint. |

There is no direct spoke-to-spoke trust path. User-defined routes keep the firewall as the
network choke point.

All address spaces are configured in `infra/main.bicep` and expanded by the resource-free
`infra/stages/00-foundation/network/address-plan.bicep` module. Its single `addressPlan` output
contains every hub and spoke VNet/subnet CIDR. VNet definitions, NSGs, route tables, firewall
rules, and cross-spoke governance consume that same object; network modules do not independently
calculate or default CIDRs.

## Platform components

- **Primary Foundry account and project** host the deployed agents.
- **BYO state stores** use private Cosmos DB, Azure AI Search, and Storage resources when the
  standard agent tier is selected.
- **Provider Foundry account** supplies the model exposed through APIM.
- **Private APIM** is the common policy enforcement point for models, MCP, Foundry agent API
  traffic, and Teams activities.
- **MCP App Service** hosts the sample MCP server behind APIM.
- **YARP App Service** is the only public ingress. Its application routes are generated from
  `agents/*/network.json`; the baked catch-all route is disabled.
- **Linux worker VM** hosts the persistent GitHub Actions runner.
- **Windows dev VM and Bastion** are optional diagnostic resources. They are not another
  deployment environment.

The standard agent tier adds private Cosmos DB, Search, and Storage resources for agent state.
The basic tier uses Microsoft-managed state stores while retaining the same private Foundry,
gateway, runner, and ingress design.

## Identities

| Actor | Identity | Uses |
|---|---|---|
| `azd` host | Operator's Azure CLI and GitHub CLI sessions | Provisioning, application deployment, repository-variable sync, runner deregistration, and teardown. |
| Linux runner | VM managed identity | Foundry agent deployment, Azure control-plane changes, ACR access, governance, and evaluation. |
| Foundry/project resources | Managed identities | Access to private state stores, Key Vault, model connections, and dependent services. |
| APIM | System-assigned managed identity | Keyless calls to the provider Foundry account and Azure control-plane discovery where configured. |
| Teams publisher | VM managed identity plus a delegated user token | Managed identity for agent and Bot Service operations; delegated token only for the Microsoft 365 publish API. |

Secrets are not embedded in agent configuration. The runner bootstrap reads its registration
credential from Key Vault, and deployment workflows use managed identity.

## Trust boundaries

### Operator boundary

The operator runs `azd` from a trusted workstation or trusted CI context. The host can reach
Azure and GitHub control planes but does not need access to the private Foundry data plane.

### Runner boundary

The self-hosted runner has private network reach and privileged managed-identity roles. It is
therefore restricted to trusted, manually dispatched repository workflows. Pull-request jobs
must not target the `self-hosted`, `vnet`, or `foundry-private` labels.

### Public ingress boundary

YARP accepts only configured routes. The Teams route is additionally restricted to Microsoft
Teams published source ranges. Requests then pass through APIM authentication and policy before
reaching Foundry.

### Private service boundary

Foundry, APIM, Key Vault, ACR, Cosmos DB, Search, Storage, and the MCP service use private
endpoints where applicable. Private DNS resolves service names to private addresses inside the
network.

## Routing

### Teams

```text
/teams/<agentName>
  -> YARP
  -> APIM Teams API
  -> /api/projects/<project>/agents/<agentName>/endpoint/protocols/activityProtocol
```

The Azure Bot Service resource is registration and channel configuration; it is not a data-path
hop. APIM validates the Bot Framework token, configured bot audience, issuer, and deployment
tenant before forwarding the original request to Foundry.

This front-door path keeps Foundry fully private. For how it compares to the
`enable_m365_public_endpoint` scoped-exception model, see
[publish-m365-vnet.md](publish-m365-vnet.md).

### Foundry agent API

```text
/agents/<agentName>/{**remainder}
  -> YARP
  -> APIM Foundry Agents API
  -> private Foundry project endpoint
```

Only agents with `exposeFoundryApi: true` receive a route. Token-limit policy is
deny-by-default for callers not listed in that agent's `network.json`.

### MCP

```text
agent -> firewall -> private APIM MCP API -> private MCP App Service
```

The workflow injects `MCP_SERVER_URL` into prompt-agent MCP tools at deployment time. APIM
validates the agent identity and applies the per-server allowlist and request rate from
`mcp/mcp-policy.json`. The private MCP App Service Easy Auth configuration independently
restricts access to the union of agent identities resolved from that policy.

### Models

```text
agent -> firewall -> private APIM inference API -> provider Foundry private endpoint
```

APIM validates the caller and uses its managed identity for the provider backend. Model
discovery and inference stay on the private route.

## Security invariants

These properties are intentional and should not be weakened:

1. `azd` is the only infrastructure and application deployment path.
2. Agent deployment, governance, evaluation, and Teams publishing are workflow-only operations
   on the private self-hosted runner.
3. Public network access is disabled for private platform services.
4. The Foundry agent subnet and Azure Firewall are deny-by-default.
5. YARP, APIM Foundry policies, APIM MCP policies, and Teams audience policies are
   deny-by-default.
6. Authentication uses managed identity except for the delegated user token required by the
   Microsoft 365 publish API.
7. Foundry and supported state stores use customer-managed keys and least-privilege RBAC.
8. APIM policy changes are applied serially to avoid conflicting management-plane writes.
9. The runner executes trusted repository workflows only.
10. Agent configuration uses unsuffixed names and variables for the single environment.

## Governance and observability notes

- The Responsible AI guardrail is an Azure Policy **Audit** initiative. It reports model
  deployments whose content-filter configuration is weaker than the configured baseline; it
  does not block deployment.
- Agent 365 telemetry resolves through Azure Front Door. The agent subnet therefore permits the
  required Front Door service tag, while Azure Firewall narrows the effective destination to
  the configured Agent 365 telemetry hostname.
- Firewall diagnostics and APIM telemetry are the primary runtime evidence for denied or failed
  paths. VNet flow logs depend on the flow-log storage account remaining writable by the Azure
  service.

## Deployment ownership

| Concern | Supported owner |
|---|---|
| Azure resources and MCP/YARP application code | `azd up`, `azd provision`, and `azd deploy` |
| Agent lifecycle | One dispatchable `deploy-<agent>.yml` workflow per agent |
| Prompt deployment | `_deploy-agent.yml` and `scripts/deploy-prompt-agent.ps1` |
| Source-zip deployment | `_deploy-code-agent.yml` and `scripts/deploy-code-agent.ps1` |
| Teams publishing | Internal `publish-teams.yml` and `scripts/publish-teams.ps1` |
| Autopilot publishing | Per-agent lifecycle workflow and `scripts/publish-autopilot.ps1` |
| Runtime governance | Internal `deploy-agent-network.yml` or the same four explicit `apply-*.ps1` steps in a hosted M365 lifecycle |
