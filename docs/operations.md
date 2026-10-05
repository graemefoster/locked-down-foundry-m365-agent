# Operations

## Prerequisites

- An Azure subscription with permission to create resources, register providers, and assign
  RBAC. The operator typically needs Azure AI account/project permissions and Owner or Role
  Based Access Administrator at the deployment scope.
- Capacity for the configured model in the selected Azure region.
- Azure CLI (`az`), Azure Developer CLI (`azd`), GitHub CLI (`gh`), PowerShell (`pwsh`), and
  `yq` v4. Image-agent deployment also requires a running Docker engine; .NET source deployment
  requires the matching .NET SDK.
- Authenticated Azure CLI and GitHub CLI sessions.
- A GitHub environment named `vnet-deploy` with required reviewers if approval is required for
  privileged workflows.
- For the self-hosted runner, a fine-grained GitHub PAT with repository Administration
  read/write permission. The bootstrap stores it in Key Vault.

Register required Azure resource providers before the first deployment. The set includes
Key Vault, Cognitive Services, Storage, Search, Network, App Service, Container Apps,
Container Registry, API Management, Bot Service, and the providers referenced by the Bicep
deployment.

## Provision the environment

`azd` is the only supported deployment path:

```bash
azd env set AZURE_LOCATION eastus
azd up
```

Set `AZURE_LOCATION` explicitly before the first deployment. The committed default is `eastus`,
but an explicit environment value prevents an unintended region if defaults change later.

`azd up` performs three categories of work:

1. provisions the Azure resources from `infra/main.bicep`;
2. deploys the MCP and YARP application services declared in `azure.yaml`;
3. runs lifecycle hooks, including GitHub variable synchronization and temporary SCM access
   management.

It does not deploy Foundry agents, apply live agent governance, run evaluations, or publish to
Teams.

Useful phase-specific commands are:

```bash
azd provision
azd deploy
azd hooks run postprovision
azd hooks run postdeploy
```

Use `azd env set NAME value` for deployment inputs. This repository has one environment; do not
create dev/test variants or suffixed workflow variables.

## Repository variables

The post-provision hook synchronizes Bicep outputs to GitHub Actions repository variables.
The single-environment outputs include:

- `AZURE_AI_PROJECT_ENDPOINT`
- `AZURE_AI_PROJECT_NAME`
- `MCP_GATEWAY_URL`
- `MCP_COMPLIANCE_AUDIENCE`
- `MCP_WEBAPP_NAME`
- `FOUNDRY_AGENTS_API_NAME`
- `FOUNDRY_AGENTS_API_PATH`
- `TEAMS_APIM_API_NAME`

Prompt-agent deployment combines `MCP_GATEWAY_URL` with each server name in `mcp/mcp.json`, so
multiple MCP tools can receive distinct APIM endpoint URLs.

If workflow variables are missing after a successful provision, authenticate `gh` with
permission to update repository variables and run:

```bash
azd hooks run postprovision
```

## Workflow order

Run the lifecycle workflow for the required agent. Each workflow deploys its agent, reconciles
shared governance, and publishes it when Microsoft 365 metadata is present.

| Agent | Workflow | Result |
|---|---|---|
| `grf-2026-teams-agent` | `deploy-grf-2026-teams-agent.yml` | Prompt deploy, governance, Teams publish |
| `grf-2026-autopilot-agent` | `deploy-grf-2026-autopilot-agent.yml` | Python source-zip deploy, governance, Autopilot publish |
| `advanced-autopilot-agent` | `deploy-advanced-autopilot-agent.yml` | Python source-zip deploy, governance, Autopilot publish |
| `support-case-agent` | `deploy-support-case-agent.yml` | .NET source-zip deploy and governance |
| `support-case-agent-ghcpsdk` | `deploy-support-case-agent-ghcpsdk.yml` | .NET source-zip deploy and governance |

The workflows share a non-cancelling concurrency group, so only one agent lifecycle updates APIM,
YARP, Easy Auth, or Teams audiences at a time. Re-run any agent lifecycle after changing
`network.json`, `mcp.json`, or `mcp-policy.json`; governance always reconciles the complete
repository state.

## Agent deployment modes

All agent workflows run on `[self-hosted, vnet, foundry-private]` and use
`scripts/deploy-agent.ps1` with `agents/<name>/agent.yaml`. The wrapper normalizes the manifest,
detects its deployment mode, packages source where required, and dispatches to the appropriate
REST deployment script.

Publishing agents expose three jobs: **deploy -> governance -> publish**. Agents without catalog
metadata expose only **deploy -> governance**. Deploy and governance use the VM managed identity;
the single delegated device-code sign-in occurs inside publish. No user token crosses job boundaries.

The six operator workflows are the five per-agent lifecycles and nightly evaluation. Five
`workflow_call`-only workflows, named `Internal: ...`, provide prompt/source/image deployment,
governance, and publishing. The image workflow is retained for supported image deployments even
though no current agent calls it. GitHub's `dynamic/...` coding-agent and dependency workflows
are platform-managed entries, not additional repository YAML.

### Prompt

`deploy-grf-2026-teams-agent.yml` invokes `.github/workflows/_deploy-agent.yml`. The wrapper
dispatches prompt manifests to:

```text
scripts/deploy-prompt-agent.ps1
```

The script creates or versions the prompt agent, maps each MCP tool to its server in
`mcp/mcp.json`, injects `<MCP_GATEWAY_URL>/<server-name>/`, and publishes the resulting version at
100 percent traffic.

### Hosted source zip

The support-agent and Autopilot workflows invoke `.github/workflows/_deploy-code-agent.yml`. The wrapper runs
`dotnet publish` for .NET agents or packages the Python source tree, places the resulting content
at the ZIP root, and dispatches to:

```text
scripts/deploy-code-agent.ps1
```

The script uploads the ZIP and the normalized `agent.json` metadata together, then publishes the
created version.

The two Autopilot workflows enable `grant-agent-project-access`; the reusable workflow passes
`-GrantAgentProjectAccess` and `-FoundryProjectId` to the deployment wrapper because their runtime
code explicitly uses the agent instance identity for
Foundry project access. `deploy-code-agent.ps1` waits for that version to become active and expose
`instance_identity.principal_id`, then grants **Foundry User on the project** before switching
traffic. This follows the official Autopilot sample's identity/RBAC sequence; it is not conditional
on M365 publishing. The script passes the principal object ID and `ServicePrincipal` type directly
to Azure CLI, avoiding a Microsoft Graph lookup. Existing assignments are accepted; other grant
failures stop deployment.

The grant uses the current Azure CLI deployment identity, which needs
`Microsoft.Authorization/roleAssignments/write` at the project scope. Bicep gives the installed
runner a project-scoped **Role Based Access Control Administrator** assignment conditioned to
allow only **Foundry User grants to service principals**; role-assignment deletion is denied.
Apply this infrastructure change with `azd provision` before running managed-identity Autopilot
deployment. Contributor alone cannot grant roles. Existing account-level agent grants are not removed.

The switch is opt-in and supported only for source agents; prompt agents, image agents, and source
agents without it retain their existing deployment behavior. For local source deployments,
`FoundryProjectId` defaults from `AZURE_AI_PROJECT_ID` and must be a full project ARM resource ID,
not the data-plane endpoint. Enable the switch only when the runtime uses its agent identity and
needs this project access.

### Hosted container image

For any image manifest, the wrapper locates the Dockerfile, builds and pushes the image, inserts
the immutable ACR image reference into the normalized manifest, and dispatches to:

```text
scripts/deploy-image-agent.ps1
```

Image deployment also uses the VM managed identity. Publishing, when configured by an agent's
caller workflow, is a separate job.

### Local or arbitrary-project deployment

After signing in with Azure CLI, deploy any agent directory with:

```bash
./scripts/deploy-agent.sh \
  -AgentDirectory agents/support-case-agent \
  -FoundryProjectEndpoint 'https://<account>.services.ai.azure.com/api/projects/<project>'
```

`FoundryProjectEndpoint`, `McpGatewayUrl`, and `AcrName` default from
`AZURE_AI_PROJECT_ENDPOINT`, `MCP_GATEWAY_URL`, and `AZURE_CONTAINER_REGISTRY_NAME`. Use
`-SourceDirectory` to select a .NET or Python source directory when automatic discovery is
ambiguous. Image agents additionally require ACR push access.

To publish an already-deployed agent, sign in as a delegated user and run:

```bash
az login --use-device-code --tenant "$TEAMS_TENANT_ID"

./scripts/publish-agent.sh \
  -AgentDirectory agents/advanced-autopilot-agent \
  -FoundryProjectEndpoint "$AZURE_AI_PROJECT_ENDPOINT"
```

The wrapper dispatches directories with `autopilot.json` to `publish-autopilot.ps1` and directories
with `teams.json` to `publish-teams.ps1`. Teams publishing additionally reads the resource group,
YARP FQDN, tenant, Bot Service name, and optional Log Analytics ID from parameters or environment
variables.

## Governance

Every agent lifecycle applies these four explicit, serialized PowerShell operations:

1. `scripts/apply-token-limits.ps1`
2. `scripts/apply-yarp-routes.ps1`
3. `scripts/apply-mcp-policy.ps1`
4. `scripts/apply-teams-audiences.ps1`

The steps intentionally do not use a common helper module or composite action.

- Token limits are compiled from every `agents/*/network.json`.
- YARP routes are regenerated and stale agent routes are removed.
- MCP agent names are resolved to live Foundry identity client IDs before the APIM policy and
  MCP App Service Easy Auth allowlist are applied.
- Teams audiences are resolved from agents enabled for Microsoft 365. Undeployed agents and
  deployed agents without an instance identity are reported and skipped. If none of the
  configured agents have live identities, the existing Teams audience policy is left unchanged.

Every agent lifecycle calls `deploy-agent-network.yml` for this sequence; the four operations
remain explicit steps inside its governance job.

An omitted agent or principal remains denied. Undeployed or identityless agents are reported and
skipped. If no live Teams identities resolve, the existing audience policy remains unchanged.

## Microsoft 365 publishing

The Teams and Autopilot lifecycles invoke `.github/workflows/publish-teams.yml`, which:

1. obtains a delegated user token through device-code authentication;
2. restores the VM managed-identity Azure session;
3. runs `scripts/publish-agent.ps1`, which dispatches to the Teams or Autopilot publishing script.

The Teams script requires `agent.yaml`, `network.json`, and `teams.json` in the selected agent
directory. It exits without publishing unless `network.json` sets `exposeToM365` to `true`.
It creates or updates the Azure Bot Service registration and publishes the Microsoft 365 app.
The activity protocol and its authorization schemes are declared in the agent's `agent.yaml`
(`agent_endpoint`) and applied by the deploy step, so publishing no longer patches them.

The bot's messaging endpoint is the public YARP route (`/teams/<agentName>`), not the Foundry
activity URL, so Foundry stays fully private. For the two publishing models (the front-door path
this repository uses and the `enable_m365_public_endpoint` alternative), see
[docs/publish-m365-vnet.md](publish-m365-vnet.md).

For an Autopilot, the publishing dispatcher selects `scripts/publish-autopilot.ps1` using
`autopilot.json`. Neither deployment nor governance requires delegated authentication.

Both publishing scripts accept the service's "version already exists" response as a successful
no-op. Keep `appVersion` unchanged when the M365 package has not changed; increment it to update
the catalog package. The publish job still authenticates and calls the API; it is not skipped
before execution.

The delegated token is used only where user authorization is required. Shared governance and
Azure resource operations use the VM managed identity.

## Evaluation

`.github/workflows/nightly-eval-agent.yml` runs on the private runner and reads the agent name
from `agents/grf-2026-teams-agent/agent.yaml`. By default it evaluates the latest version.

Manual inputs can select explicit `name:version` values and a baseline. Version-over-version
comparison invokes Foundry cluster analysis, which is not supported in a Private BYO-network
workspace. Use the default single-version evaluation for this deployment.

## Runner operations

The Linux runner is required for all private data-plane workflows. It is installed only when
the runner repository URL and PAT are supplied during provisioning.

Fresh installations use the runner version pinned by `GITHUB_RUNNER_VERSION` (default
`2.337.0`). Existing registered runners use GitHub's normal self-update behavior. Update the
pin when GitHub raises the minimum version accepted for new runner registration, then rerun
`azd provision`.

Expected labels:

```text
self-hosted, vnet, foundry-private
```

The runner is trusted-only. Do not add pull-request triggers to workflows using these labels.
The optional Windows dev VM and Bastion are for human diagnostics and do not replace the runner.

## Teardown

```bash
azd down
```

The pre-down hook:

1. deregisters the deterministic self-hosted runner with the operator's `gh` session;
2. deletes project capability hosts;
3. deletes account capability hosts;
4. allows `azd` to remove the remaining Azure resources.

If the GitHub cleanup cannot run, remove the offline runner in repository settings. Capability
host deletion failures should be resolved before retrying `azd down`.
