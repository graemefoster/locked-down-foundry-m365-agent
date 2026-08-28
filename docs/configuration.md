# Configuration

## Agent directory contract

Each deployable agent has a directory under `agents/`:

```text
agents/<name>/
├── agent.json       # required
├── network.json     # optional
└── teams.json       # optional
```

`agent.json` is the canonical deployment manifest for prompt, source-zip, and container-image
agents. An `agent.yaml` inside an application source project is source metadata for that
application; workflows must not treat it as the deployment manifest.

Use unsuffixed values. There are no dev/test variants of agent files, routes, or repository
variables.

## `agent.json`

All modes require:

- a non-empty `name`;
- a `definition`;
- optional `description` and `metadata`.

Keep the directory name and agent `name` aligned.

### Prompt agent

```json
{
  "object": "agent.version",
  "name": "weather-agent",
  "description": "Answers weather questions through the governed MCP connection.",
  "definition": {
    "kind": "prompt",
    "model": "model-gateway/gpt-5.4-mini",
    "instructions": "Answer clearly and concisely.",
    "tools": [
      {
        "type": "mcp",
        "server_label": "weather",
        "project_connection_id": "weather",
        "require_approval": "never"
      }
    ]
  }
}
```

Do not commit a generated `server_url`. `scripts/deploy-prompt-agent.ps1` injects
`MCP_SERVER_URL` into each MCP tool immediately before deployment. The
`project_connection_id` remains in the file because it supplies the agentic identity
connection.

### Hosted source-zip agent

```json
{
  "object": "agent.version",
  "name": "support-agent",
  "description": "Hosted source-zip agent.",
  "definition": {
    "kind": "hosted",
    "protocol_versions": [
      {
        "protocol": "responses",
        "version": "2.0.0"
      }
    ],
    "cpu": "0.5",
    "memory": "1Gi",
    "code_configuration": {
      "runtime": "dotnet_10",
      "entry_point": [
        "dotnet",
        "Support.Agent.dll"
      ],
      "dependency_resolution": "bundled"
    },
    "environment_variables": {
      "AZURE_AI_MODEL_DEPLOYMENT_NAME": "gpt-5.4"
    }
  }
}
```

The reusable source-zip workflow builds the application and packages the publish output at the
archive root. If `FOUNDRY_PROJECT_ENDPOINT` is present in `environment_variables`,
`scripts/deploy-code-agent.ps1` replaces it with `AZURE_AI_PROJECT_ENDPOINT` at deployment time.

### Hosted container-image agent

```json
{
  "object": "agent.version",
  "name": "image-agent",
  "description": "Hosted container-image agent.",
  "definition": {
    "kind": "hosted",
    "container_protocol_versions": [
      {
        "protocol": "responses",
        "version": "2.0.0"
      }
    ],
    "cpu": "1",
    "memory": "2Gi",
    "image": "",
    "environment_variables": {
      "AZURE_AI_MODEL_DEPLOYMENT_NAME": "model-gateway/gpt-5.4-mini"
    }
  }
}
```

Leave `definition.image` empty in the committed manifest. `scripts/deploy-image-agent.ps1`
builds and pushes the image, then inserts the immutable run-specific image reference before
creating the Foundry version.

## `network.json`

`network.json` is optional. Omitting it leaves the agent without YARP exposure, token-limit
grants, or Teams audience configuration.

```json
{
  "exposeToM365": true,
  "exposeFoundryApi": true,
  "tokenLimits": {
    "agentRef": "weather-agent",
    "principals": [
      {
        "email": "user@example.com",
        "tokensPerMinute": 10000
      },
      {
        "appId": "11111111-1111-1111-1111-111111111111",
        "tokensPerMinute": 30000,
        "tokenQuota": 1000000,
        "tokenQuotaPeriod": "Daily"
      }
    ]
  }
}
```

Rules:

- `exposeToM365: true` creates `/teams/<agentName>` and makes the agent eligible for Teams
  audience resolution and publishing.
- `exposeFoundryApi: true` creates `/agents/<agentName>/{**remainder}`.
- Agent directory names used in routes may contain letters, digits, dots, and hyphens.
- `tokenLimits.agentRef` defaults to the directory name and may contain letters, digits, dots,
  underscores, asterisks, and hyphens.
- Every principal must have `email`, `appId`, or both.
- `appId` must be a GUID. `tokensPerMinute` and an optional `tokenQuota` must be positive.
- `tokenQuotaPeriod`, when present, is `Hourly`, `Daily`, `Weekly`, `Monthly`, or `Yearly`.
- An agent with no token principals remains denied at the Foundry Agents API.
- Governance regeneration removes stale YARP routes.

## `teams.json`

`teams.json` is required only for Teams/Microsoft 365 publishing.

```json
{
  "displayName": "Weather Agent",
  "publishScope": "Shared",
  "appVersion": "1.0.0",
  "shortDescription": "Governed weather assistance.",
  "fullDescription": "A Foundry agent published from the private environment.",
  "developerName": "Contoso",
  "developerWebsiteUrl": "https://www.example.com",
  "privacyUrl": "https://www.example.com/privacy",
  "termsOfUseUrl": "https://www.example.com/terms"
}
```

`displayName` defaults to the agent name, `publishScope` defaults to `Shared`, and
`appVersion` defaults to `1.0.0`. Increment `appVersion` when publishing updated catalog
metadata. Publishing also requires `network.json` with `exposeToM365: true`.

## `mcp/mcp.json`

This file declares the MCP servers exposed through APIM:

```json
{
  "servers": [
    {
      "name": "weather",
      "connectionName": "weather"
    }
  ]
}
```

Rules:

- `name` is unique and determines the APIM API name and path.
- `connectionName` is unique and determines the Foundry project connection name.
- `connectionName` may be omitted when it is the same as `name`.
- Backend FQDNs and token audiences are deployment outputs, not committed values.
- Adding an MCP server also requires the infrastructure mapping that supplies its backend FQDN.

## `mcp/mcp-policy.json`

This file declares which named agents may call each MCP server:

```json
{
  "renewalPeriodSeconds": 60,
  "servers": [
    {
      "name": "weather",
      "agents": [
        {
          "name": "weather-agent",
          "requestsPerMinute": 60
        }
      ]
    }
  ]
}
```

Rules:

- `renewalPeriodSeconds` and every `requestsPerMinute` value must be positive.
- The governance workflow resolves each agent name to its live
  `instance_identity.client_id`.
- An unresolved or identity-less agent is omitted and remains denied.
- An agent not listed for a server receives `403`; permission on one server does not grant
  access to another.
- Apply changes through `deploy-agent-network.yml`, not a direct APIM deployment.

## Workflow variables

Use unsuffixed repository variables for the single environment:

| Variable | Purpose |
|---|---|
| `AZURE_AI_PROJECT_ENDPOINT` | Private Foundry project endpoint used by agent, governance, Teams, and eval workflows. |
| `AZURE_AI_PROJECT_NAME` | Foundry project name. |
| `MCP_GATEWAY_URL` | Deployed MCP gateway URL exported by infrastructure. |
| `MCP_SERVER_URL` | Workflow-facing copy of `MCP_GATEWAY_URL`. |
| `MCP_COMPLIANCE_AUDIENCE` | Audience accepted by the MCP APIM policy. |
| `MCP_WEBAPP_NAME` | MCP App Service name. |
| `FOUNDRY_AGENTS_API_NAME` | APIM Foundry Agents API resource name. |
| `FOUNDRY_AGENTS_API_PATH` | APIM path prefix used when constructing backend routes. |
| `TEAMS_APIM_API_NAME` | APIM Teams API resource name used by YARP route generation. |

Existing shared variables such as the resource group, APIM names, Foundry account name,
container registry name, model deployment, YARP host, Teams tenant, Bot Service name, and Log
Analytics workspace remain unsuffixed and are consumed directly by the workflows.
