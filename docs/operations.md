# Operations

## Prerequisites

- An Azure subscription with permission to create resources, register providers, and assign
  RBAC. The operator typically needs Azure AI account/project permissions and Owner or Role
  Based Access Administrator at the deployment scope.
- Capacity for the configured model in the selected Azure region.
- Azure CLI (`az`), Azure Developer CLI (`azd`), GitHub CLI (`gh`), and PowerShell (`pwsh`).
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

It also synchronizes the existing shared variables used by the workflows. `MCP_GATEWAY_URL` is
copied to `MCP_SERVER_URL` because agent deployment consumes `MCP_SERVER_URL`.

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
| `support-case-agent` | `deploy-support-case-agent.yml` | .NET source-zip deploy and governance |
| `support-case-agent-ghcpsdk` | `deploy-support-case-agent-ghcpsdk.yml` | .NET source-zip deploy and governance |
| `gfdiag10-fef839` | `deploy-gfdiag10-fef839.yml` | Python source-zip deploy, governance, Autopilot publish |
| `gfdiag11` | `deploy-gfdiag11.yml` | Python source-zip deploy, governance, Autopilot publish |

The workflows share a non-cancelling concurrency group, so only one agent lifecycle updates APIM,
YARP, Easy Auth, or Teams audiences at a time. Re-run any agent lifecycle after changing
`network.json`, `mcp.json`, or `mcp-policy.json`; governance always reconciles the complete
repository state.

## Agent deployment modes

All agent workflows run on `[self-hosted, vnet, foundry-private]` and use
`agents/<name>/agent.yaml`, normalized to JSON with `yq` at deployment time.

### Prompt

`deploy-grf-2026-teams-agent.yml` invokes `.github/workflows/_deploy-agent.yml`, which runs:

```text
scripts/deploy-prompt-agent.ps1
```

The script creates or versions the prompt agent, injects `MCP_SERVER_URL` into any MCP tool, and
publishes the resulting version at 100 percent traffic.

### Hosted source zip

The support-agent workflows invoke `.github/workflows/_deploy-code-agent.yml`. The reusable
workflow builds the application, places publish output at the ZIP root, creates `agent.zip`, and
runs:

```text
scripts/deploy-code-agent.ps1
```

The script uploads the ZIP and the normalized `agent.json` metadata together, then publishes the
created version.

The hosted M365 workflows package their Python source directly so deployment and publication can
share one delegated user token.

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

`deploy-agent-network.yml` provides the same sequence as internal `workflow_call` automation for
the prompt and support-agent workflows. The hosted M365 workflows retain the four explicit steps
inside their single job so deployment and publication require only one delegated sign-in.

An omitted agent or principal remains denied. Undeployed or identityless agents are reported and
skipped. If no live Teams identities resolve, the existing audience policy remains unchanged.

## Microsoft 365 publishing

The Teams-agent lifecycle invokes `.github/workflows/publish-teams.yml`, which:

1. obtains a delegated user token through device-code authentication;
2. restores the VM managed-identity Azure session;
3. runs `scripts/publish-teams.ps1`.

The script requires `agent.yaml`, `network.json`, and `teams.json` in the selected agent
directory. It exits without publishing unless `network.json` sets `exposeToM365` to `true`.
It creates or updates the Azure Bot Service registration and publishes the Microsoft 365 app.
The activity protocol and its authorization schemes are declared in the agent's `agent.yaml`
(`agent_endpoint`) and applied by the deploy step, so publishing no longer patches them.

The bot's messaging endpoint is the public YARP route (`/teams/<agentName>`), not the Foundry
activity URL, so Foundry stays fully private. For the two publishing models (the front-door path
this repository uses and the `enable_m365_public_endpoint` alternative), see
[docs/publish-m365-vnet.md](publish-m365-vnet.md).

The Autopilot lifecycle workflows acquire one delegated token, deploy while the delegated user is
active, switch Azure CLI to the VM managed identity for governance, then pass the saved delegated
token to `scripts/publish-autopilot.ps1`.

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
