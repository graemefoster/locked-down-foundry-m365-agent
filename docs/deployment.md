# Deployment guide

> **Level 2 — Automate agent deployment.** Part of the
> [locked-down Foundry agent](../README.md) reference implementation. The in-VNet runner that
> makes private-endpoint agent deployment possible: [github-runner.md](./github-runner.md).

How to provision the environment, then seed agents from inside the VNet. See the
[README](../README.md) for the quick start and [architecture.md](./architecture.md) for the
resource deep dive.

## Prerequisites

- **Azure subscription** where you can register resource providers and assign RBAC. You need
  **Azure AI Account Owner** (create the Foundry account + project), **Owner** or **Role Based
  Access Administrator** (assign RBAC on Cosmos/Search/Storage), and **Azure AI User** (create
  and edit agents).
- **`az` CLI**, **`azd`**, **`gh`**, and **`pwsh`** installed and logged in.
- Sufficient **model quota** in your target region.
- **Register resource providers** (once per subscription):

  ```bash
  for ns in Microsoft.KeyVault Microsoft.CognitiveServices Microsoft.Storage \
            Microsoft.Search Microsoft.Network Microsoft.App Microsoft.ContainerService; do
    az provider register --namespace "$ns"
  done
  ```

The template always creates a **fresh, fully isolated** set of resources (VNet + subnets,
Cosmos DB, AI Search, Storage, Key Vault, ACR, private DNS zones and endpoints). Bringing your
own Search / Storage / Cosmos / DNS / VNet is **not supported** — it creates everything itself
to stay self-contained.

## Provision with `azd`

[`azd`](https://aka.ms/azd) is the only supported path. All infrastructure lives under
[`infra/`](../infra), wired through [`azure.yaml`](../azure.yaml).

```bash
azd up          # provision infra, then deploy the MCP + YARP app code (no agents)
# or run the phases separately:
azd provision   # infrastructure only
azd deploy      # (re)deploy just the two App Service code services
```

- `azd` reads [`infra/main.parameters.json`](../infra/main.parameters.json), which maps each
  Bicep param to an env var with an inline default (`${VAR=default}`). A fresh `azd up` uses
  those defaults. Override any value with `azd env set VAR value` before provisioning.
- `vmAdminPassword` has no default and is omitted from `main.parameters.json`, so `azd` prompts
  for it interactively — it is never stored in the repo.
- The **deploy** phase ships the two App Services as **code** (no containers): the private MCP
  server ([`mcp/agent-tools`](../mcp/agent-tools), Node) and the public YARP Teams edge
  ([`apps/sample-gateway`](../apps/sample-gateway), .NET). Both SCM (Kudu) sites are
  deny-by-default, so the `predeploy` hook opens them for your public IP, azd zip-deploys, and
  `postdeploy` re-locks them. **No agents** are deployed — the `postprovision` hook only pushes
  the azd outputs into GitHub Actions repo variables (`gh variable set`) so the workflows below
  just work.

> **Access the private Foundry endpoint** only from inside the VNet (VM, VPN, or ExpressRoute).

> **CMK / Key Vault propagation retry.** Provisioning may fail the first time with
> `KeyVaultAuthenticationFailure` / `AccessPolicyNotConfiguredForKeyVault`. This is an RBAC
> role-assignment propagation delay (1–5 min for the Key Vault Crypto role to reach the KV data
> plane) — the deployment is **idempotent**, so just re-run `azd provision`.

> **AI Search service-level CMK is a preview feature.** The STANDARD tier enables CMK
> enforcement on the AI Search service and sets a **service-level customer-managed key** (so new
> indexes/indexers/skillsets inherit it by default) via
> `infra/stages/10-platform/encryption/search-encryption.bicep`. This uses the Search Management
> API `2026-03-01-preview` — the first version to support `encryptionWithCmk.serviceLevelEncryptionKey`
> — which is in **preview** (no SLA, not for production) and is **not** exposed in the Azure
> portal, only via ARM/Bicep. The key applies to newly created objects only; pre-existing objects
> keep their prior encryption state. If the service-level key were absent while enforcement is on,
> every new object would fail unless it carried its own object-level key.

## Deploy agents (from the in-VNet runner)

The Foundry endpoint is private, so agents are created on the **in-VNet self-hosted GitHub
Actions runner** (the locked-down VM), which runs natively as the VM's managed identity. Enable
it first — see [github-runner.md](./github-runner.md).

**One agent per workflow.** Each agent has a manifest (`agents/<name>/agent.yaml`) and a thin
caller workflow (`deploy-<name>-agent.yml`) that calls the reusable
[`_deploy-agent.yml`](../.github/workflows/_deploy-agent.yml). The reusable workflow converts the
manifest with `yq`, injects the MCP `server_url` if present, then creates/updates the agent
version and publishes it.

```bash
gh workflow run deploy-teams-agent.yml   # also publishes to Teams (gated by vnet-deploy)
```

- Deploys are **idempotent** — an existing agent (matched by name) gets a fresh version.
- **To add an agent:** add a manifest folder under `agents/` and copy an existing
  `deploy-*-agent.yml` caller.
- The VM's managed identity already holds **Foundry User** on the project, so
  `create-agent.ps1` / `publish-agent.ps1` call the Agents API via IMDS — no `az login`.
- Per-agent workflows are `workflow_dispatch`-only and repository-guarded; the optional
  Teams-publish job is gated by the `vnet-deploy` environment (add a required reviewer for an
  approval gate).
