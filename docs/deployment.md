# Deployment guide

> **Level 2 — Automate agent deployment.** Part of the
> [locked-down Foundry agent](../README.md) reference implementation. The in-VNet runner that
> makes private-endpoint agent deployment possible: [github-runner.md](./github-runner.md).

How to deploy, seed agents, and operate the network-secured Foundry agent environment. See the [README](../README.md) for the quick start and [architecture.md](./architecture.md) for the resource/design deep dive.

## Prerequisites

1. **Active Azure subscription with appropriate permissions**
   - **Azure AI Account Owner**: Needed to create a cognitive services account and project 
   - **Owner or Role Based Access Administrator**: Needed to assign RBAC to the required resources (Cosmos DB, Azure AI Search, Storage) 
   - **Azure AI User**: Needed to create and edit agents

1. **Register Resource Providers**

   Make sure you have an active Azure subscription that allows registering resource providers. For example, subnet delegation requires the Microsoft.App provider to be registered in your subscription. If it's not already registered, run the commands below:

   ```bash
   az provider register --namespace 'Microsoft.KeyVault'
   az provider register --namespace 'Microsoft.CognitiveServices'
   az provider register --namespace 'Microsoft.Storage'
   az provider register --namespace 'Microsoft.Search'
   az provider register --namespace 'Microsoft.Network'
   az provider register --namespace 'Microsoft.App'
   az provider register --namespace 'Microsoft.ContainerService'
   ```

1. Network administrator permissions (if operating in a restricted or enterprise environment)

1. Sufficient quota for all resources in your target Azure region
    * If no parameters are passed in, this template creates an Azure AI Foundry resource, Foundry project, Azure Cosmos DB for NoSQL, Azure AI Search, and Azure Storage account
1. Azure CLI installed and configured on your local workstation or deployment pipeline server

## Pre-Deployment Steps

### Networking Requirements
1. Review network requirements and plan Virtual Network address space (e.g., 192.168.0.0/16 or an alternative non-overlapping address space)

2. Two subnets are needed as well:  
    - **Agent Subnet** (e.g., 192.168.0.0/24): Hosts Agent client for Agent workloads, delegated to Microsoft.App/environments. The recommended size should be /24 for this delegated subnet. 
    - **Private endpoint Subnet** (e.g. 192.168.1.0/24): Hosts private endpoints 
    - Ensure that the address spaces for these subnets do not overlap with any existing networks in your Azure environment or reserved IP ranges like the following: 169.254.0.0/16, 172.30.0.0/16, 172.31.0.0/16, 192.0.2.0/24, 0.0.0.0/8, 127.0.0.0/8, 100.100.0.0/17, 100.100.192.0/19, 100.100.224.0/19, 10.0.0.0/8.
  
  > **Notes:** 
  - If you do not provide an existing virtual network, the template will create a new virtual network with the default address spaces and subnets described above. If you use an existing virtual network, make sure it already contains two subnets (Agent and Private Endpoint) before deploying the template.
  - You must ensure the Foundry account was successfully created so that underlying caphost has also succeeded. Then proceed to deploying the project caphost bicep. 
  - You must ensure the subnet is not already in use by another account. It must be an exclusive subnet for the Foundry account.
  - You must ensure the subnet is exclusively delegated to __Microsoft.App/environments__ and cannot be used by any other Azure resources.
  

### Account Deletion Prerequisites and Cleanup Guidance

Before deleting an **Account** resource, it is essential to first delete the associated **Account Capability Host**.  
Failure to do so may result in residual dependencies—such as subnets and other provisioned resources (e.g., ACA applications)—remaining linked to the capability host.  
This can lead to errors such as **"Subnet already in use"** when attempting to reuse the same subnet in a different account deployment.

**Cleanup Options**

**1. Full Account Removal**:
You may delete and purge the account.  
The service will automatically handle the deletion of the associated capability host and any linked resources in the background.

**2. Retain Account, Remove Capability Host**:
If you intend to retain the account but remove the capability host, you can use the script `deleteCaphost.sh` located in this folder.

> **Important**: Before deleting the account capability host, ensure that the **project capability host** is deleted.



### Template Customization

This template always provisions a fresh, fully isolated set of resources in the target
resource group:

- VNet and two subnets
- Azure Cosmos DB for NoSQL
- Azure AI Search
- Azure Storage
- Azure Key Vault
- Azure Container Registry
- Private DNS zones and private endpoints for all of the above

Bringing your own (pre-existing) Search, Storage, Cosmos DB, DNS zones, or VNet is **not**
supported — the template creates everything itself to keep the deployment simple and
self-contained.

## Deploy with `azd`

[Azure Developer CLI](https://aka.ms/azd) (`azd`) is the only supported deployment path.
All infrastructure lives under [`infra/`](../infra) and is wired through
[`azure.yaml`](../azure.yaml).

```bash
azd up          # provision infrastructure ONLY (azd deploys no agents post-provision)
# or, equivalently:
azd provision
```

`azd` reads [`infra/main.parameters.json`](../infra/main.parameters.json), which maps each
Bicep parameter to an `azd` environment variable with an inline default (`${VAR=default}`).
A fresh `azd up` uses those defaults with no extra setup. Override any value per environment
before provisioning:

```bash
azd env set AZURE_LOCATION eastus2
```

`vmAdminPassword` has no Bicep default and is deliberately **omitted** from
`main.parameters.json`, so `azd` prompts for it interactively at provision time — it is
never stored in the repo.

> **Note:** To access your Foundry resource securely, use either a VM, VPN, or ExpressRoute.

> **Note:** `azd` **only provisions infrastructure** — it deploys no agents. Its sole
> post-provision step is the `postprovision` hook, which pushes the azd outputs into the repo's
> GitHub Actions variables (`gh variable set`) so the deploy workflows work without hand-copying
> values. Agent seeding, MCP compliance and Teams / M365 publishing all run from the in-VNet
> self-hosted GitHub Actions runner (see below).

> **Note — CMK / Key Vault propagation:** provisioning may occasionally fail the first time
> with `KeyVaultAuthenticationFailure` / `AccessPolicyNotConfiguredForKeyVault`
> ("managed identity is forbidden ... to wrap & unwrap"). This is an Azure RBAC
> **role-assignment propagation delay** — the Key Vault Crypto role granted to the AI Services
> and Storage identities can take 1–5 minutes to become effective in the Key Vault data plane,
> and the customer-managed-key (CMK) enablement step sometimes runs before it propagates. The
> deployment is **idempotent**: simply re-run `azd provision` (or `azd up`). The already-created
> resources are skipped and the CMK step succeeds once the roles have propagated.

---

## Deploying agents

The Foundry endpoint is private, so agents are created/updated **on the locked-down VM** (the
only host inside the VNet that can reach the private endpoint). azd no longer does this — it runs
on the **in-VNet self-hosted GitHub Actions runner**, which executes natively on the VM as its
managed identity. So you must have the runner enabled
(see [docs/github-runner.md](./github-runner.md)).

**One agent per workflow.** Each agent has a manifest (`agents/<name>/agent.yaml`) and a thin
caller workflow (`deploy-<name>-agent.yml`) that calls the reusable
[`deploy-agent.yml`](../.github/workflows/deploy-agent.yml). The reusable workflow converts the
manifest with `yq`, injects the MCP `server_url` if the manifest has an
MCP tool, then creates/updates the agent version and publishes it. Once infrastructure is
provisioned and the runner is installed:

```bash
# Deploy (or re-deploy) an agent from inside the VNet — run whichever you need:
gh workflow run deploy-hello-world-agent.yml
gh workflow run deploy-gateway-model-agent.yml
gh workflow run deploy-teams-agent.yml       # also publishes to Teams (gated by vnet-deploy)
gh workflow run deploy-test-agent-one.yml
```

To add an agent, add a manifest folder under `agents/` and a thin caller workflow (copy an
existing `deploy-*-agent.yml`). Deploys are **idempotent** — an existing agent (matched by name)
gets a fresh version rather than a duplicate, so re-running is safe.

**Requirements:**
- The in-VNet self-hosted runner must be installed (`GITHUB_RUNNER_REPO_URL` set before
  provisioning). The runner VM's managed identity already holds **Foundry User** on the project
  (granted by the template), so `create-agent.ps1` / `publish-agent.ps1` call the Agents API via
  IMDS — no `az login` needed.
- The per-agent workflows are `workflow_dispatch`-only, guarded by a repository check; the
  optional Teams-publish job is gated by the `vnet-deploy` environment (add a required reviewer
  for an approval gate).

## Maintenance

### Regular Tasks

1. Review role assignments
2. Monitor network security
3. Check service health
4. Update configurations as needed

### Troubleshooting

1. Verify private endpoint connectivity
2. Check DNS resolution
3. Validate role assignments
4. Review network security groups

**`KeyVaultAuthenticationFailure` / `AccessPolicyNotConfiguredForKeyVault` during provisioning**
— an RBAC role-assignment propagation delay, not a misconfiguration. The CMK enablement step
occasionally runs before the Key Vault Crypto role (granted to the AI Services / Storage
identities) becomes effective in the Key Vault data plane (1–5 min). Re-run `azd provision` —
the deployment is idempotent and succeeds on the retry.
