# Architecture deep dive

> **Cross-cutting foundation** (underpins all three levels). Part of the
> [locked-down Foundry agent](../README.md) reference implementation.

Resource-by-resource detail. For the rule-by-rule networking reference see
[NETWORKING.md](./NETWORKING.md); for deployment steps see [deployment.md](./deployment.md).

## Core Foundry concepts

- **Foundry account** (`Microsoft.CognitiveServices`, kind `AIServices`) — the top-level
  resource that holds connections and networking/policy config.
- **Foundry project** — an isolated workspace inside the account. All agents in a project share
  the same file storage, thread (conversation) storage, and search indexes; data is isolated
  between projects. The project is the unit of sharing and isolation.
- **Bring-Your-Own (BYO) data plane** — agents are stateful, and their state lives in **your
  own** resources, not Microsoft-managed ones: **Storage** (files), **AI Search** (vector
  stores), **Cosmos DB** (threads/history). Locking down the agent means locking down all three.

## Resources created

Everything is created with **public network access disabled**, private endpoints, managed
identity (no stored credentials), and TLS 1.2+.

| Resource | Type | Notable config |
|---|---|---|
| Azure AI Foundry | `Microsoft.CognitiveServices/accounts` (AIServices, S0) | Custom subdomain, network ACLs deny-by-default, system-assigned MI, CMK. |
| Model deployment | `.../accounts/deployments` | Name/format/version/SKU/capacity from `model*` params. |
| Azure AI Search | `Microsoft.Search/searchServices` (standard) | AAD auth (401 challenge), system MI, semantic search off, CMK (service-level key, enforced). |
| Storage | `Microsoft.Storage/storageAccounts` (StorageV2, ZRS/GRS) | Blob + Queue, block public blob access, SharedKey disabled (force AAD). |
| Cosmos DB | `Microsoft.DocumentDB/databaseAccounts` (SQL API) | Session consistency, local auth disabled, single region. |
| Key Vault, ACR | | Private, used for CMK + container builds. |

Containers are provisioned automatically during the capability-host process: two Storage blob
containers (`<workspaceId>-azureml-blobstore`, `<workspaceId>-agents-blobstore`) and three
Cosmos containers (`<projectWorkspaceId>-{thread-message,system-thread-message,agent-entity}-store`).

## Private DNS zones

| Resource | Private DNS zone(s) |
|---|---|
| Azure AI Foundry | `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com`, `privatelink.services.ai.azure.com` |
| Azure AI Search | `privatelink.search.windows.net` |
| Azure Cosmos DB | `privatelink.documents.azure.com` |
| Azure Storage (blob) | `privatelink.blob.core.windows.net` |
| Azure API Management | `privatelink.azure-api.net` |

## Key RBAC role assignments

System-assigned managed identities are granted least-privilege data-plane roles:

- **AI Search** — Search Index Data Contributor, Search Service Contributor.
- **Storage** — Storage Blob Data Owner (+ Storage Queue Data Contributor if the Azure Function
  tool is enabled); the auto-provisioned blobstores get Blob Data Contributor / Owner.
- **Cosmos DB** — Cosmos DB Operator + Built-in Data Contributor.

## Module structure

```text
infra/
├── main.bicep                  # Thin orchestrator: params + stage calls + azd outputs
├── main.parameters.json        # azd parameter file (${VAR=default} env bindings)
└── stages/                     # Sequential stages (deps: 00 ← 10 ← 13 ← 15 ← 20 ← 30 ← 40)
    ├── 00-foundation/          # Networking (hub + spokes, DNS resolver, firewall, flow logs) + observability
    ├── 10-platform/            # Key Vault, ACR, Cosmos/Storage/Search, App Service + YARP, APIM/provider Foundry, PEs, Storage + Search CMK
    ├── 13-foundry/             # Foundry account + model + PE, KV/App Insights RBAC, account CMK
    ├── 15-foundry-project/     # AI project + BYO connections, project RBAC, Agents capability host
    ├── 20-workload-mcp/        # MCP web app, app registration, builtin-auth, APIM MCP servers
    ├── 30-governance/          # MCP connections, APIM policies/compliance/lockdown, RAI guardrail, Teams API, firewall rules
    └── 40-runner/              # Linux worker VM (+ optional Windows dev VM / Bastion), runner RBAC, PAT secret, runner extension
```

Each stage co-locates the Bicep modules it owns under category subfolders (`network/`,
`foundry/`, `rbac/`, `resources/`, `encryption/`, `gateway/`, `governance/`, `model-gateway/`) —
there is no shared `infra/modules/` tree.
