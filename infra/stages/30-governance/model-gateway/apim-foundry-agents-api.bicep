/*
  Model-Gateway: Foundry agent multi-protocol passthrough API (structure only)
  ----------------------------------------------------------------------------
  Fronts the PRIMARY Foundry project's agent surface through APIM so agent
  invocations can be metered + throttled + auth-gated at the edge. This module owns
  only the STRUCTURE (API + backend + wildcard operations); the inbound POLICY
  (validate-jwt + llm-emit-token-metric + deny-by-default llm-token-limit + the
  path-preserving rewrite to the Foundry agent endpoint) is authored by the sibling
  apim-foundry-agent-limits.bicep so the deploy-agent-network workflow can re-apply
  just the policy after agents/<name>/network.json changes — exactly the split
  used by the MCP api (structure) + apim-mcp-compliance (policy) pair.

    Web tier / user  --Entra JWT-->  THIS APIM API (/<foundry>/<proj>/agents/<name>/...)
      -> policy rewrites to /api/projects/<proj>/agents/<name>/endpoint/protocols/...
         -> forward to the primary Foundry account over its private endpoint (APIM
            outbound VNet integration -> firewall -> foundry PE, the SAME egress the
            Teams API already uses).

  Path shape (multi-protocol): a Foundry agent exposes SEVERAL protocol endpoints under
  one agent name (…/agents/<name>/endpoint/protocols/{openai/responses | invocations | …}).
  Rather than a per-protocol operation, this API is a path-preserving passthrough — mirroring
  the Teams API's path-routed pattern. The API path is '<foundryAccount>/<project>', so callers
  hit https://<apim>/<foundryAccount>/<project>/agents/<name>/endpoint/protocols/... and the
  policy (a) reads <name> from the URL path for metering/throttling and (b) rewrites the whole
  /agents/<name>/... tail onto /api/projects/<project>/agents/<name>/... — everything after
  'agents/<name>' is proxied through unchanged.

  Auth posture:
    * Inbound: the policy (in apim-foundry-agent-limits.bicep) validates the caller's Entra
      token; the caller identity (email / appid) is used ONLY for metering + throttling.
    * Backend: APIM forwards the caller's ORIGINAL Authorization header (their Entra token) to
      Foundry UNCHANGED — Foundry authorizes the END USER directly (data-plane RBAC on the caller,
      not on APIM's MI). This is the same pass-through posture as the teams API. APIM's MI needs
      NO Foundry data-plane role for this path.
*/

@description('Name of the existing APIM instance.')
param apimName string

@description('Name of the primary Foundry (Cognitive Services) account that hosts the project/agents.')
param foundryAccountName string

@description('Name of the primary Foundry project.')
param projectName string

@description('APIM API resource name (stable id the policy module attaches to). The public PATH is derived separately from the account/project.')
param apiName string = 'foundry-agents'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// First-class backend for the primary Foundry account data plane. The policy targets it by ID
// and rewrites to the Responses path; APIM forwards over VNet integration -> firewall -> PE.
var backendId = 'foundry-agents-${foundryAccountName}'
var backendBaseUrl = 'https://${foundryAccountName}.services.ai.azure.com'

// Public path = '<account>/<project>' (per the design). The account/project prefix is only for
// addressing/routing at the edge; the policy rewrites onto the Foundry agent endpoint path.
var apiPath = '${foundryAccountName}/${projectName}'

resource foundryAgentsBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: backendId
  properties: {
    title: 'Primary Foundry account (agent passthrough)'
    description: 'Primary Foundry account private endpoint; APIM rewrites to the agent protocol endpoint and forwards over VNet integration -> firewall -> Foundry PE.'
    protocol: 'http'
    url: backendBaseUrl
  }
}

resource foundryAgentsApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: apiName
  properties: {
    displayName: 'Foundry agent passthrough (governed)'
    path: apiPath
    protocols: [
      'https'
    ]
    // The caller presents its own Entra JWT (validated in the policy); there is no APIM
    // subscription key. Backend auth is APIM's managed identity (keyless).
    subscriptionRequired: false
    // No serviceUrl: the policy routes to the `foundryAgentsBackend` backend by ID.
  }
}

// Path-preserving wildcard passthrough: one operation per HTTP method matching
// /agents/{agentName}/* (agentName plus the whole protocol tail). The API-level policy
// (apim-foundry-agent-limits.bicep) reads the agent from the URL path and rewrites the
// tail onto /api/projects/<project>/agents/<name>/endpoint/protocols/..., so ONE API +
// policy serves every agent and every protocol (openai/responses, invocations, …) — no
// per-agent, per-protocol re-provision. Foundry agent protocols are POST/GET (streaming +
// retrieval); PUT/DELETE/PATCH are included so the passthrough is complete.
var passthroughMethods = [
  'GET'
  'POST'
  'PUT'
  'DELETE'
  'PATCH'
]

resource agentPassthroughOperations 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = [
  for method in passthroughMethods: {
    parent: foundryAgentsApi
    name: 'agents-${toLower(method)}'
    properties: {
      displayName: 'Agents passthrough (${method})'
      method: method
      urlTemplate: '/agents/{agentName}/*'
      templateParameters: [
        {
          name: 'agentName'
          description: 'Seeded Foundry agent name; the whole /agents/<name>/... tail is proxied to that agent.'
          type: 'string'
          required: true
        }
      ]
      description: 'Governed agent passthrough: APIM meters tokens (llm-emit-token-metric), enforces the per-caller deny-by-default token limit, then rewrites the /agents/<name>/... tail onto the Foundry agent endpoint before forwarding.'
    }
  }
]

@description('APIM API resource name (attach the limits policy to this).')
output apiName string = foundryAgentsApi.name

@description('Public API path (<account>/<project>).')
output apiPath string = foundryAgentsApi.properties.path

@description('Backend entity ID the policy targets.')
output backendId string = backendId
