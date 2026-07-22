---
description: This set of templates demonstrates how to set up Azure AI Agent Service with virtual network isolation with private network links to connect the agent to your secure data.
page_type: sample
products:
- azure
- azure-resource-manager
urlFragment: network-secured-agent
languages:
- bicep
- json
---
# Azure AI Agent Service: Standard Agent Setup with E2E Network Isolation

## Overview

Infrastructure-as-code for a **network-secured Azure AI Foundry agent**: a dedicated
virtual network, private endpoints for every dependency, customer-managed-key encryption,
and RBAC — public network access disabled by default. [`azd`](https://aka.ms/azd) is the
only supported deployment path.

Optionally, it can front models with an **APIM model gateway** and **publish an agent to
Microsoft Teams / M365 Copilot** — all while staying inside the private network.

## What gets deployed

- **Azure AI Foundry** account + project (private endpoint, public access off, CMK).
- **BYO data plane:** Azure Cosmos DB (threads), Azure AI Search (vectors), Azure Storage
  (files) — all private-endpoint only.
- **Networking:** hub + spoke VNets, Azure Firewall (deny-by-default egress), private DNS
  zones, a locked-down VM for in-VNet access, and VNet flow logs.
- **Always-on shared APIM** (Standard v2, private) used by the optional model-gateway and
  Teams paths.
- Key Vault + Container Registry (private), and all supporting role assignments.

See **[docs/architecture.md](./docs/architecture.md)** for the resource-by-resource detail
and **[NETWORKING.md](./NETWORKING.md)** for the rule-by-rule network lockdown.

## Quick start

**Prerequisites:** an Azure subscription where you can register resource providers and
assign RBAC (Azure AI Account Owner + Role Based Access Administrator or Owner), the
[`az` CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli),
[`azd`](https://aka.ms/azd), and PowerShell (`pwsh`). Full list + provider registration:
**[docs/deployment.md](./docs/deployment.md)**.

```bash
# 1. Provision all infrastructure (azd prompts for the VM admin password)
azd up

# 2. Seed agents on the private VM (runs the predeploy hook)
azd hooks run predeploy
```

`azd` reads defaults from [`infra/main.parameters.json`](./infra/main.parameters.json);
override any value with `azd env set VAR value`. Provisioning may need one retry on a
transient Key Vault CMK propagation delay — it is idempotent. Details, seeding options,
and troubleshooting: **[docs/deployment.md](./docs/deployment.md)**.

## Optional capabilities

- **Publish an agent to Teams / M365 Copilot** *(on by default)* — exposes the seeded
  agent to Microsoft Teams even though Foundry is private, via a public YARP proxy →
  private APIM → the agent's activityProtocol endpoint, with Bot Framework JWT validation
  and single-tenant lockdown. **[docs/teams-m365.md](./docs/teams-m365.md)**.
- **Model gateway (APIM + provider Foundry)** *(off by default)* — front models with APIM
  Standard v2 (private), dynamic model discovery, and defense-in-depth auth.
  **[docs/model-gateway.md](./docs/model-gateway.md)** ·
  [deep dive](./apim-model-gateway.md).

## Documentation

| Doc | What's inside |
|-----|---------------|
| [docs/deployment.md](./docs/deployment.md) | Prerequisites, pre-deployment planning, `azd` deploy, seeding agents, maintenance & troubleshooting. |
| [docs/architecture.md](./docs/architecture.md) | Resource-by-resource deep dive, private DNS zones, RBAC, module structure. |
| [NETWORKING.md](./NETWORKING.md) | Rule-by-rule network lockdown: NSG, firewall, flow logs, validation. |
| [docs/teams-m365.md](./docs/teams-m365.md) | Publish an agent to Teams / M365 Copilot (inbound path, hooks, JWT). |
| [docs/model-gateway.md](./docs/model-gateway.md) · [apim-model-gateway.md](./apim-model-gateway.md) | Optional APIM model gateway overview + full walkthrough. |

## References

- [Azure AI Foundry Networking Documentation](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/configure-private-link?tabs=azure-portal&pivots=fdp-project)
- [Azure AI Foundry RBAC Documentation](https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/rbac-azure-ai-foundry?pivots=fdp-project)
- [Private Endpoint Documentation](https://learn.microsoft.com/en-us/azure/private-link/)
- [RBAC Documentation](https://learn.microsoft.com/en-us/azure/role-based-access-control/)
- [Network Security Best Practices](https://learn.microsoft.com/en-us/azure/security/fundamentals/network-best-practices)
