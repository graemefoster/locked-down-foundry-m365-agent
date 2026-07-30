/*
  Model-Gateway: Foundry agent /responses inbound API (structure only)
  --------------------------------------------------------------------
  Fronts the PRIMARY Foundry project's Responses API through APIM so agent
  invocations can be metered + throttled at the edge. This module owns only the
  STRUCTURE (API + backend + operation); the inbound POLICY (validate-jwt +
  llm-emit-token-metric + deny-by-default llm-token-limit) is authored by the
  sibling apim-foundry-agent-limits.bicep so the deploy-agent-limits workflow can
  re-apply just the policy after agents/<name>/limits.json changes — exactly the split
  used by the MCP api (structure) + apim-mcp-compliance (policy) pair.

    Web tier / user  --Entra JWT-->  THIS APIM API (/<foundry>/<proj>/responses)
      -> rewrite to the Foundry Responses endpoint -> forward to the primary
         Foundry account over its private endpoint (APIM outbound VNet integration
         -> firewall -> foundry PE, the SAME egress the Teams API already uses).

  Path shape (per the design): the API path is '<foundryAccount>/<project>', so callers
  POST to https://<apim>/<foundryAccount>/<project>/responses and the policy rewrites to
  the backend Responses path (backendResponsesPath), dropping the public prefix.

  Auth posture:
    * Inbound: the policy (in apim-foundry-agent-limits.bicep) validates the caller's Entra
      token; the caller identity (email / appid) is used ONLY for metering + throttling.
    * Backend: APIM authenticates to Foundry with its OWN managed identity (keyless), so
      APIM's MI must hold a Foundry data-plane role (e.g. "Azure AI User") on the project.
      This is the same keyless posture as the model-gateway inference API.
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
// addressing/routing at the edge; the policy rewrites to the Foundry Responses path.
var apiPath = '${foundryAccountName}/${projectName}'

resource foundryAgentsBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: backendId
  properties: {
    title: 'Primary Foundry account (Responses API)'
    description: 'Primary Foundry account private endpoint; APIM rewrites to the Responses endpoint and forwards over VNet integration -> firewall -> Foundry PE.'
    protocol: 'http'
    url: backendBaseUrl
  }
}

resource foundryAgentsApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: apiName
  properties: {
    displayName: 'Foundry agent responses (governed)'
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

// Single POST operation: callers POST to /<account>/<project>/responses; the policy rewrites
// to the backend Responses path. One operation + policy serves every agent (the agent is
// selected in the request body and read by the policy for scoping/metering).
resource responsesOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: foundryAgentsApi
  name: 'post-responses'
  properties: {
    displayName: 'Post Responses'
    method: 'POST'
    urlTemplate: '/responses'
    description: 'Governed agent invocation: caller posts a Responses request; APIM meters tokens (llm-emit-token-metric) and enforces the per-caller deny-by-default token limit before forwarding to Foundry.'
  }
}

@description('APIM API resource name (attach the limits policy to this).')
output apiName string = foundryAgentsApi.name

@description('Public API path (<account>/<project>).')
output apiPath string = foundryAgentsApi.properties.path

@description('Backend entity ID the policy targets.')
output backendId string = backendId
