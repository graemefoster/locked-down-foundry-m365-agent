---
description: Deploy and operate a network-isolated Azure AI Foundry agent platform with private automation and optional Microsoft Teams publishing.
page_type: sample
products:
- azure
- azure-resource-manager
urlFragment: network-secured-agent
languages:
- bicep
- json
- powershell
---

# Locked-down Azure AI Foundry agents

This repository is a reference implementation for deploying Azure AI Foundry agents into a
private Azure landing zone and operating them from an in-VNet GitHub Actions runner.

The repository manages **one Azure/Foundry environment**. There are no dev/test deployment
lanes or promotion steps. The optional Windows **dev VM** is a machine role for interactive
diagnostics, not a separate environment.

## Architecture summary

- `azd` is the only supported path for provisioning infrastructure and deploying the MCP and
  YARP application code.
- Foundry, its state stores, Key Vault, ACR, and API Management use private endpoints and
  managed identities. Public access is disabled except for the deliberately public,
  IP-restricted YARP endpoint used by Microsoft Teams.
- The persistent Linux VM is a private, trusted-only GitHub Actions runner. Agent deployment,
  governance changes, evaluations, and Teams publishing run there because the Foundry data
  plane is private.
- One private APIM instance governs model, MCP, Foundry agent, and Teams traffic.
- YARP exposes only routes explicitly generated from agent configuration:
  - `/teams/<agentName>`
  - `/agents/<agentName>/{**remainder}`
- MCP access, Foundry token limits, YARP routes, and Teams audiences are deny-by-default.
- Teams publishing uses the VM managed identity for Azure and Foundry operations. Only the
  Microsoft 365 publish call uses a delegated user token.

See [docs/architecture.md](docs/architecture.md) for the topology, identities, trust
boundaries, routing, and security invariants.

## Shortest supported lifecycle

### 1. Provision infrastructure and application code

Install and authenticate the Azure CLI, Azure Developer CLI, GitHub CLI, and PowerShell, then:

```bash
azd env set AZURE_LOCATION eastus
azd up
```

`azd up` provisions the single environment, deploys the MCP and YARP applications, and runs the
post-provision variable sync. It does **not** deploy Foundry agents.

### 2. Run an agent lifecycle

Each agent has one dispatchable workflow that deploys the agent, reconciles the shared governance
configuration, and publishes it when `teams.json` or `autopilot.json` is present:

```bash
gh workflow run deploy-grf-2026-teams-agent.yml
gh workflow run deploy-grf-2026-autopilot-agent.yml
gh workflow run deploy-support-case-agent.yml
gh workflow run deploy-support-case-agent-ghcpsdk.yml
gh workflow run deploy-gfdiag10-fef839.yml
gh workflow run deploy-gfdiag11.yml
```

All workflows run on the private self-hosted runner and consume
`agents/<name>/agent.yaml` (normalized to JSON with `yq` at deploy time). Governance applies token
limits, YARP routes, the MCP allowlist, and Teams audiences in order. Workflows that publish to
Microsoft 365 prompt for delegated device-code authentication.

### 3. Tear down

```bash
azd down
```

The pre-down hook deregisters the runner and removes Foundry capability hosts before Azure
resource deletion.

## Agent configuration

The deployment configuration for an agent lives under `agents/<name>/`:

- `agent.yaml` — required deployment definition (normalized to JSON via `yq` at deploy time)
- `network.json` — optional exposure and token-limit policy
- `teams.json` — optional Teams/Microsoft 365 metadata

Source-project `agent.yaml` files inside application source trees are not deployment manifests.
See [docs/configuration.md](docs/configuration.md) for examples and validation rules.

## Documentation

- [Architecture](docs/architecture.md)
- [Operations](docs/operations.md)
- [Configuration](docs/configuration.md)
- [Publish to Microsoft 365 and Teams](docs/publish-m365-vnet.md)
- [Troubleshooting](docs/troubleshooting.md)
