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
# Locked-down Azure AI Foundry agent, published to Microsoft Teams / M365 Copilot

A network-isolated Azure AI Foundry agent — private VNet, private endpoints on every
dependency, deny-by-default firewall egress, CMK encryption, and RBAC — that can still be
**published to Microsoft Teams / M365 Copilot** and optionally front its models through a
private APIM model gateway.

## Overview

Infrastructure-as-code, deployed with [`azd`](https://aka.ms/azd) (the only supported
path). Public network access is disabled by default — everything talks over private
endpoints inside the VNet, with egress forced through a deny-by-default Azure Firewall.

## What gets deployed

- **Azure AI Foundry** account + project (private endpoint, public access off, CMK).
- **BYO data plane:** Azure Cosmos DB (threads), Azure AI Search (vectors), Azure Storage
  (files) — all private-endpoint only.
- **Networking:** hub + spoke VNets, Azure Firewall (deny-by-default egress), private DNS
  zones, a locked-down VM for in-VNet access, and VNet flow logs.
- **Always-on shared APIM** (Standard v2, private) fronting the Teams and model-gateway paths.
- **Teams / M365 publish path** *(on by default):* a public YARP proxy (App Service, VNet
  integrated, Teams-IP restricted), an MCP web app, and an Azure Bot Service registration
  that points the Teams channel at the agent.
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
# 1. Provision all infrastructure
#    azd prompts for the VM admin password, and a preprovision hook asks (once)
#    whether to deploy the Windows dev VM and/or the in-VNet self-hosted runner.
azd up
```

azd **only provisions the infrastructure** — it deploys no agents. The one thing it does after
provisioning is a lightweight host-side `postprovision` hook that copies the azd outputs into the
repo's GitHub Actions variables (via `gh variable set`) so the workflows below "just work". Agent
seeding, MCP compliance and Teams / M365 publishing all run from the **in-VNet self-hosted GitHub
Actions runner** (which reaches the private Foundry endpoint directly), so enable the runner (step
below) and then:

```bash
# 2. Deploy agents from inside the VNet (requires the self-hosted runner).
#    One workflow per agent — run whichever you need:
gh workflow run deploy-hello-world-agent.yml
gh workflow run deploy-gateway-model-agent.yml
gh workflow run deploy-teams-agent.yml      # also publishes to Teams (gated)
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
- **Model gateway (APIM + provider Foundry)** *(on by default)* — front models with APIM
  Standard v2 (private), dynamic model discovery, and defense-in-depth auth.
  **[docs/model-gateway.md](./docs/model-gateway.md)** ·
  [deep dive](./apim-model-gateway.md).
- **RAI guardrail policy (Azure Policy · Audit)** *(on by default)* — assigns the built-in
  "Guardrail for Cognitive Services Deployments" initiative with a strict content-filter
  baseline that audits every model deployment. Audit-only (reports, does not block); an
  optional flag deploys a deliberately non-compliant model to see it flagged.
  **[docs/rai-guardrail-policy.md](./docs/rai-guardrail-policy.md)**.
- **In-VNet self-hosted GitHub Actions runner** *(off by default)* — installs a runner on
  the in-VNet **Linux** worker VM so complex deployments run *inside the VNet*, reaching
  the private Foundry endpoint directly. It is now **required** for post-provision steps
  (agent seeding, MCP compliance, Teams publishing), since azd itself deploys no agents (its
  only post-provision step is syncing repo variables).
  `azd up`'s preprovision hook prompts for the repo URL (or set `GITHUB_RUNNER_REPO_URL` directly).
  **[docs/github-runner.md](./docs/github-runner.md)**.
- **Optional Windows dev VM** *(off by default)* — the RDP-in-and-run-Edge box for
  inspecting the environment from behind the firewall. All automation lives on the Linux
  worker VM, so this stays off unless you want that interactive session: `azd up`'s
  preprovision hook prompts for it (or set `DEPLOY_WINDOWS_VM true`), which also brings up
  Azure Bastion to reach it.

## Documentation

| Doc | What's inside |
|-----|---------------|
| [docs/deployment.md](./docs/deployment.md) | Prerequisites, pre-deployment planning, `azd` deploy, seeding agents, maintenance & troubleshooting. |
| [docs/architecture.md](./docs/architecture.md) | Resource-by-resource deep dive, private DNS zones, RBAC, module structure. |
| [NETWORKING.md](./NETWORKING.md) | Rule-by-rule network lockdown: NSG, firewall, flow logs, validation. |
| [docs/teams-m365.md](./docs/teams-m365.md) | Publish an agent to Teams / M365 Copilot (inbound path, hooks, JWT). |
| [docs/model-gateway.md](./docs/model-gateway.md) · [apim-model-gateway.md](./apim-model-gateway.md) | Optional APIM model gateway overview + full walkthrough. |
| [docs/rai-guardrail-policy.md](./docs/rai-guardrail-policy.md) | RAI content-filter guardrail (Azure Policy, Audit): strict baseline, why it can't block, the non-compliant demo, compliance checks. |
| [docs/github-runner.md](./docs/github-runner.md) | Optional in-VNet self-hosted GitHub Actions runner: security model, auth, setup. |
| [BACKLOG.md](./BACKLOG.md) | Project backlog: aim, goals, and epics for evolving this reference implementation. |

## References

- [Azure AI Foundry Networking Documentation](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/configure-private-link?tabs=azure-portal&pivots=fdp-project)
- [Azure AI Foundry RBAC Documentation](https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/rbac-azure-ai-foundry?pivots=fdp-project)
- [Private Endpoint Documentation](https://learn.microsoft.com/en-us/azure/private-link/)
- [RBAC Documentation](https://learn.microsoft.com/en-us/azure/role-based-access-control/)
- [Network Security Best Practices](https://learn.microsoft.com/en-us/azure/security/fundamentals/network-best-practices)
