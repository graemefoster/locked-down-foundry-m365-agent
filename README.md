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

> **IMPORTANT**
> 
> Class A subnet support is GA and available in the following regions. **Supported regions: Australia East, Brazil South, Canada East, East US, East US 2, France Central, Germany West Central, Italy North, Japan East, South Africa North, South Central US, South India, Spain Central, Sweden Central, UAE North, UK South, West Europe, West US, West US 3.**
>
> Class B and C subnet support is already GA and available in all regions supported by Azure AI Foundry Agent Service. Deployment templates and setup steps are identical for Class A, B, and C subnets. For more on the supported regions of the Azure AI Foundry Agent service, see [Models supported by Azure AI Foundry Agent Service](https://learn.microsoft.com/en-us/azure/ai-foundry/agents/concepts/model-region-support?tabs=global-standard)

> **IMPORTANT**
> 
> To use your existing APIM resource with Azure AI Foundry in a network isolated environment to build Agents, please deploy this template. The feature is currently in preview with a code first experience and no Foundry UI support. 


---
## Overview
This infrastructure-as-code (IaC) solution deploys a network-secured Azure AI agent environment with private networking and role-based access control (RBAC).

> 🔒 **Network lockdown reference:** for the full, rule-by-rule breakdown of the deny-by-default firewall and agent-subnet NSG (service-tag allow-list, flow logs, and validation steps), see **[NETWORKING.md](./NETWORKING.md)**.


Standard setup provides private network isolation through a **dedicated virtual network with subnet delegation** that the template creates and manages for you.

This implementation gives you full control over the inbound and outbound communication paths for your agent. You can restrict access to only the resources explicitly required by your agent, such as storage accounts, databases, or APIs, while blocking all other traffic by default. This approach ensures that your agent operates within a tightly scoped network boundary, reducing the risk of data leakage or unauthorized access. By default, this setup simplifies security configuration while enforcing strong isolation guarantees, ensuring that each agent deployment remains secure, compliant, and aligned with enterprise networking policies. 

---

## Key Information

**Region and Resource Placement Requirements**
- **All Foundry workspace resources should be in the same region as the VNet**, including CosmosDB, Storage Account, AI Search, Foundry Account, Project, Managed Identity. The only exception is within the Foundry Account, you may choose to deploy your model to a different region, and any cross-region communication will be handled securely within our network infrastructure.
  - **Note:** Your Virtual Network can be in a different resource group than your Foundry workspace resources


---

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

---

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

---

## Optional: Model Gateway (APIM + provider Foundry)

Set `enableModelGateway=true` (default **false**) to deploy an optional,
enterprise-grade model gateway in a **new spoke** (`10.3.0.0/16`):

- **APIM Standard v2** with an inbound **private endpoint** and outbound **VNet
  integration** — no public gateway access.
- A minimal **provider AI Foundry** account (public access disabled, private
  endpoint only) exposing a `gpt-5.4-mini` deployment behind APIM.
- An `ApiManagement` connection advertising APIM to the primary Foundry project,
  and a **second seeded agent** using the model `model-gateway/gpt-5.4-mini`.

Models are discovered **dynamically**: instead of a static list, APIM exposes
`GET /deployments` and `GET /deployments/{name}`, which proxy the provider account's
**Azure Resource Manager** deployments API and return the AzureOpenAI-format list the
Foundry connection parses at runtime.

Auth is defense-in-depth: callers must present **both** a valid Entra JWT
(`validate-azure-ad-token`) **and** an APIM subscription **`api-key`** (sent by the
connection). APIM authenticates to the provider Foundry with its own managed
identity — granted **Cognitive Services User** (data-plane inference) and **Reader**
(ARM deployments read for discovery) on the provider account. APIM logs to both Log
Analytics and the shared **Application Insights** component. See [NETWORKING.md](./NETWORKING.md#optional-model-gateway-spoke-apim--provider-foundry).

Key parameters (see [`infra/main.parameters.json`](./infra/main.parameters.json)):

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `enableModelGateway` | `false` | Master switch for the whole gateway spoke. |
| `gatewayModelName` | `gpt-5.4-mini` | Model deployed on the provider and exposed via APIM. |
| `gatewayCallerAppId` | `''` | Optional caller app/client ID pinned in the JWT policy. |
| `gatewayApiKey` | `''` (secure) | Optional explicit `api-key`; empty = deterministic derived key. |

> **Note:** APIM Standard v2 provisioning is slow (~15–45 min), so enabling this
> materially increases deployment time.

---

## Deploy with `azd`

[Azure Developer CLI](https://aka.ms/azd) (`azd`) is the only supported deployment path.
All infrastructure lives under [`infra/`](./infra) and is wired through
[`azure.yaml`](./azure.yaml).

```bash
azd up          # provision infrastructure (+ predeploy hook once a service is defined)
# or, to provision only:
azd provision
```

`azd` reads [`infra/main.parameters.json`](./infra/main.parameters.json), which maps each
Bicep parameter to an `azd` environment variable with an inline default (`${VAR=default}`).
A fresh `azd up` uses those defaults with no extra setup. Override any value per environment
before provisioning:

```bash
azd env set ENABLE_MODEL_GATEWAY false
azd env set AZURE_LOCATION eastus2
```

`vmAdminPassword` has no Bicep default and is deliberately **omitted** from
`main.parameters.json`, so `azd` prompts for it interactively at provision time — it is
never stored in the repo.

> **Note:** To access your Foundry resource securely, use either a VM, VPN, or ExpressRoute.

> **Note:** `azd provision` creates all infrastructure but **does not seed agents**. Seed
> them separately (see below).

---

## Seeding agents

The Foundry endpoint is private, so agents are created by running
[`scripts/seed-agents.ps1`](./scripts/seed-agents.ps1) **on the locked-down VM** (the only
host inside the VNet that can reach the private endpoint). This is wired as an
[Azure Developer CLI](https://aka.ms/azd) **`predeploy` hook**
([`hooks/predeploy.ps1`](./hooks/predeploy.ps1)), which uses `az vm run-command` to execute
the script on the VM.

Once infrastructure is provisioned (so the Bicep outputs are in the azd environment):

```bash
# Iterate on agents without re-provisioning:
azd hooks run predeploy

# Or, as part of a full deploy (runs the predeploy hook first):
azd deploy
```

To change which agents are created, edit the `$agentsToCreate` array in
`scripts/seed-agents.ps1`. The script is **idempotent** — agents that already exist (matched
by name) are skipped, so re-running is safe.

**Requirements:**
- `az` CLI and PowerShell (`pwsh`) on the machine running the hook.
- The caller needs permission to invoke VM run-commands
  (`Microsoft.Compute/virtualMachines/runCommands/*`, e.g. **Virtual Machine Contributor**
  on the VM/resource group). The VM's own managed identity already holds **Foundry User** on
  the project (granted by the template) so the on-VM script can call the Agents API.
- `azd deploy` only triggers the hook once a service is defined in `azure.yaml`;
  `azd hooks run predeploy` works regardless and is the quickest way to (re)seed.

To (re)seed agents manually — for example outside the hook or from another host inside the
VNet — run the seeding script yourself, e.g. `az vm run-command invoke --command-id
RunPowerShellScript --name <vm-name> -g <rg> --scripts @scripts/seed-agents.ps1 --parameters
"FoundryProjectEndpoint=<endpoint>" "ModelDeploymentName=<model>"`.

---

## Network Secured Agent Project Architecture Deep Dive

### Core Components

**Azure AI Foundry** resource
- Central orchestration point
- Manages service connections
- Set networking and policy configurations

**Foundry** project
- Defines the workspace configuration 
- Service integration 
- Agents are created within a specific project, and each project acts as an isolated workspace. This means:
  - All agents in the same project share access to the same file storage, thread storage (conversation history), and search indexes.
  - Data is isolated between projects. Agents in one project cannot access resources from another. Projects are currently the unit of  sharing and isolation in Foundry. See the what is AI foundry article for more information on Foundry projects. 

**Bring Your Own (BYO) Azure Resources**: ensures all sensitive data remains under customer control. All agents created using our service are stateful, meaning they retain information across interactions. With this setup, agent states are automatically stored in customer-managed, single-tenant resources. The required Bring Your Own Resources include: 
- BYO File Storage: All files uploaded by developers (during agent configuration) or end-users (during interactions) are stored directly in the customer’s Azure Storage account.
- BYO Search: All vector stores created by the agent leverage the customer’s Azure AI Search resource.
- BYO Thread Storage: All customer messages and conversation history will be stored in the customer’s own Azure Cosmos DB account.

By bundling these BYO features (file storage, search, and thread storage), the standard setup guarantees that your deployment is secure by default. All data processed by Azure AI Foundry Agent Service is automatically stored at rest in your own Azure resources, helping you meet internal policies, compliance requirements, and enterprise security standards.

### Azure Resources Created

Azure AI Foundry (Cognitive Services)
- Type: Microsoft.CognitiveServices/accounts
- API version: 2025-04-01-preview
- Kind: AIServices
- SKU: S0
- Identity: System-assigned
- Features:
  - Custom subdomain name
  - Disabled public network access
  - Network ACLs with Azure Services bypass 

AI Model Deployment 
- Type: Microsoft.CognitiveServices/accounts/deployments 
- API version: 2025-04-01-preview
- SKU: Based on modelSkuName parameter, capacity set by modelCapacity 
- Model properties:
  - Name: From modelName parameter
  - Format: From modelFormat parameter
  - Version: From modelVersion parameter 

Azure AI Search 
- Type: Microsoft.Search/searchServices
- API version: 2024-06-01-preview
- SKU: standard 
- Partition Count: 1 
- Replica Count: 1 
- Hosting Mode: default 
- Semantic Search: disabled
- Features:
  -  Disabled public network access
  -  AAD auth with HTTP 401 challenge
  -  System-assigned managed identity

Storage Account 
- Type: Microsoft.Storage/storageAccounts 
- API version: 2023-05-0
- Kind: StorageV2 
- SKU: ZRS or GRS (region dependent; use Standard_GRS if ZRS not available) 
- Features:
  - Blob service, Queue service (if Azure Function Tool supported)
  - Minimum TLS Version: 1.2
  - Block public blob access
  - Disabled public network access
  - Force Azure AD authentication (SharedKey access disabled) 

Cosmos DB Account 
- Type: Microsoft.DocumentDB/databaseAccounts 
- API version: 2024-11-15 
- Kind: GlobalDocumentDB (SQL API) 
- Consistency Level: Session 
- Database Account Offer Type: Standard 
- Features:
  - Disabled public network access
  - Disabled local auth
  - Single region deployment 

### Network Security Design
This implementation uses a dedicated virtual network with subnet delegation. The template creates the virtual network and one delegated subnet for the agent.

Network Security
- Public network access disabled
- Private endpoints for all services
- Network ACLs with deny by default

**Network Infrastructure**
- A Virtual Network (192.168.0.0/16) is created (if existing isn't passed in)
- Agent Subnet (192.168.0.0/24): Hosts Agent client
- Private endpoint Subnet (192.168.1.0/24): Hosts private endpoints

**Private Endpoints** 
Private endpoints ensure secure, internal-only connectivity. Private endpoints are created for the following:
- Azure AI Foundry
- Azure AI Search
- Azure Storage
- Azure Cosmos DB
- Azure API Management (if provided)

**Private DNS Zones**
| Private Link Resource Type | Sub Resource | Private DNS Zone Name | Public DNS Zone Forwarders |
|----------------------------|--------------|------------------------|-----------------------------|
| **Azure AI Foundry**       | account      | `privatelink.cognitiveservices.azure.com`<br>`privatelink.openai.azure.com`<br>`privatelink.services.ai.azure.com` | `cognitiveservices.azure.com`<br>`openai.azure.com`<br>`services.ai.azure.com` |
| **Azure AI Search**        | searchService| `privatelink.search.windows.net` | `search.windows.net` |
| **Azure Cosmos DB**        | Sql          | `privatelink.documents.azure.com` | `documents.azure.com` |
| **Azure Storage**          | blob         | `privatelink.blob.core.windows.net` | `blob.core.windows.net` |
| **Azure API Management** (Optional) | Gateway     | `privatelink.azure-api.net` | `azure-api.net` |

### Authentication & Authorization

- **Managed Identity**
  - Zero-trust security model
  - No credential storage
  - Platform-managed rotation

  This template uses System Managed Identity, but User Assigned Managed Identity is also supported.

- **Role Assignments**
  - **Azure AI Search**
    - Search Index Data Contributor (`8ebe5a00-799e-43f5-93ac-243d3dce84a7`)
    - Search Service Contributor (`7ca78c08-252a-4471-8644-bb5ff32d4ba0`)
  - **Azure Storage Account**
    - Storage Blob Data Owner (`b7e6dc6d-f1e8-4753-8033-0f276bb0955b`)
    - Storage Queue Data Contributor (`974c5e8b-45b9-4653-ba55-5f855dd0fb88`) (if Azure Function tool enabled)
    - Two containers will automatically be provisioned during the project create capability host process:
      - Azure Blob Storage Container: `<workspaceId>-azureml-blobstore`
        - Storage Blob Data Contributor
      - Azure Blob Storage Container: `<workspaceId>-agents-blobstore`
        - Storage Blob Data Owner
  - **Cosmos DB for NoSQL**
    - Cosmos DB Operator (`230815da-be43-4aae-9cb4-875f7bd000aa`)
    - Cosmos DB Built-in Data Contributor
    - Three containers will automatically be provisioned during the create capability host process:
      - Cosmos DB for NoSQL container: `<${projectWorkspaceId}>-thread-message-store`
      - Cosmos DB for NoSQL container: `<${projectWorkspaceId}>-system-thread-message-store`
      - Cosmos DB for NoSQL container: `<${projectWorkspaceId}>-agent-entity-store`


---

## Module Structure

```text
infra/
├── main.bicep                  # Orchestrator: wires all modules + emits azd outputs
├── main.parameters.json        # azd parameter file (${VAR=default} env bindings)
└── modules/
    ├── network/                # VNets (hub + spokes), subnets, peering, DNS resolver,
    │                           #   firewall, private endpoints, flow logs
    ├── foundry/                # AI account/project identity, capability host,
    │                           #   workspace-id formatting
    ├── resources/              # ACR, Key Vault, VM, App Service, dependent resources
    │                           #   (Cosmos/Storage/Search)
    ├── encryption/             # CMK encryption for ACR, AI account, Storage
    ├── rbac/                   # All role assignments (incl. VM → Foundry User)
    └── model-gateway/          # Optional APIM Standard v2 + provider Foundry spoke
```

> **Note:** The template always creates the VNet and delegates the Agents subnet to `Microsoft.App/environments` for you.

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

---

## References

- [Azure AI Foundry Networking Documentation](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/configure-private-link?tabs=azure-portal&pivots=fdp-project)
- [Azure AI Foundry RBAC Documentation](https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/rbac-azure-ai-foundry?pivots=fdp-project)
- [Private Endpoint Documentation](https://learn.microsoft.com/en-us/azure/private-link/)
- [RBAC Documentation](https://learn.microsoft.com/en-us/azure/role-based-access-control/)
- [Network Security Best Practices](https://learn.microsoft.com/en-us/azure/security/fundamentals/network-best-practices)
