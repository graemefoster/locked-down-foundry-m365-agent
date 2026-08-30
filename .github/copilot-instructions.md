# Copilot instructions — locked-down Foundry M365 agent

This repository deploys one network-isolated Azure AI Foundry environment. There are no
dev/test environments or promotion stages. The optional Windows dev VM is a diagnostic machine
role only.

## Supported lifecycle

- Use `azd` exclusively for infrastructure and application deployment:
  - `azd up`
  - `azd provision`
  - `azd deploy`
  - `azd down`
- `azd` deploys Azure resources plus the MCP and YARP application code. It does not deploy
  agents, apply live agent governance, run evaluations, or publish to Teams.
- Agent deployment, governance, Teams publishing, and evaluation are GitHub Actions operations
  on the private self-hosted runner.
- Do not add direct `az deployment` paths as an alternative lifecycle.

## Repository layout

| Path | Purpose |
|---|---|
| `infra/` | Bicep infrastructure consumed by `azd`. |
| `azure.yaml` | `azd` services and lifecycle hooks. |
| `hooks/` | Host-side `azd` lifecycle operations. |
| `agents/<name>/agent.yaml` | Canonical deployment definition for every prompt, source-zip, or image agent. Deploy workflows normalize it to JSON with `yq` before the REST scripts consume it. |
| `agents/<name>/network.json` | Optional YARP exposure and Foundry token-limit policy. |
| `agents/<name>/teams.json` | Optional Teams/Microsoft 365 catalog metadata. |
| `mcp/mcp.json` | MCP servers exposed through APIM. |
| `mcp/mcp-policy.json` | Per-server agent allowlist and request limits. |
| `scripts/` | Runner-side PowerShell entry points invoked directly by workflows. |
| `.github/workflows/` | Caller and reusable workflows for agent operations. |
| `docs/` | Canonical architecture, operations, configuration, and troubleshooting docs. |

The deployment manifest is `agents/<name>/agent.yaml`. An `agent.yaml` that lives inside an
application source project is source metadata for that application, not a deployment manifest. Do
not add environment-suffixed agent manifests or repository variables.

## Agent automation

The supported PowerShell operations are:

- `scripts/deploy-prompt-agent.ps1`
- `scripts/deploy-code-agent.ps1`
- `scripts/deploy-image-agent.ps1`
- `scripts/publish-teams.ps1`
- `scripts/apply-token-limits.ps1`
- `scripts/apply-yarp-routes.ps1`
- `scripts/apply-mcp-policy.ps1`
- `scripts/apply-teams-audiences.ps1`

Keep these as explicit workflow steps. Do not introduce a common agent helper module or
composite actions.

Reusable workflows are separated by operation:

- `_deploy-agent.yml` — prompt agent
- `_deploy-code-agent.yml` — hosted source zip
- `_deploy-hosted-agent.yml` — hosted container image
- `publish-teams.yml` — Teams/Microsoft 365 publishing

`deploy-agent-network.yml` must retain four explicit, serialized script steps in this order:

1. apply token limits;
2. apply YARP routes;
3. apply the MCP policy;
4. apply Teams audiences.

The nightly evaluation workflow reads `agents/grf-2026-teams-agent/agent.yaml`.

## Variables and routes

Use unsuffixed outputs and repository variables. Important names include:

- `AZURE_AI_PROJECT_ENDPOINT`
- `AZURE_AI_PROJECT_NAME`
- `MCP_GATEWAY_URL`
- `MCP_SERVER_URL`, synchronized from `MCP_GATEWAY_URL`
- `MCP_COMPLIANCE_AUDIENCE`
- `MCP_WEBAPP_NAME`
- `FOUNDRY_AGENTS_API_NAME`
- `FOUNDRY_AGENTS_API_PATH`
- `TEAMS_APIM_API_NAME`

Keep existing shared variables unsuffixed.

Generated public routes are exactly:

- `/teams/<agentName>`
- `/agents/<agentName>/{**remainder}`

Do not add environment path prefixes.

## Security invariants

- Private endpoints and private DNS protect Foundry and dependent services.
- The in-VNet runner uses managed identity and runs trusted repository workflows only.
- A delegated user token is allowed only for Microsoft 365 publishing.
- Foundry and state stores retain CMK and least-privilege RBAC controls.
- YARP, APIM Foundry policies, MCP policies, and Teams audiences remain deny-by-default.
- APIM writes remain serialized.
- Temporary SCM access opened by `azd deploy` must be relocked by the post-deploy hook.

## Documentation

Keep documentation concise and update the canonical files instead of adding overlapping guides:

- `README.md` — purpose, architecture summary, shortest lifecycle
- `docs/architecture.md` — topology, identities, boundaries, routing, invariants
- `docs/operations.md` — deployment and workflow operations
- `docs/configuration.md` — JSON contracts and examples
- `docs/troubleshooting.md` — recovery and known limitations

When behavior changes, update the smallest relevant canonical document and avoid duplicating
long explanations across files.
