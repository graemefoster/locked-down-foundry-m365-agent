/*
  Model-Gateway: APIM MCP server API
  -----------------------------------
  Exposes the private MCP web app (App Service) through APIM as a first-class
  MCP-type API. The Foundry MCP connection points at this APIM endpoint instead
  of directly at the App Service private endpoint, so all MCP traffic flows
  through the enterprise model gateway.

  Auth posture: pass-through. The Foundry agent presents an AgenticIdentityToken
  (Entra JWT minted for the MCP app registration's audience). APIM forwards it
  unchanged to the MCP web app backend, where App Service built-in auth validates
  it. No APIM subscription key is required (subscriptionRequired = false) and
  APIM does NOT swap the token — the original Authorization header is preserved.

  The backend is the MCP web app's private endpoint, reached by APIM outbound
  VNet integration -> firewall -> App Service spoke pe-subnet.

  Uses the preview API version (2024-06-01-preview) for `type: 'mcp'` and
  `mcpProperties` support.
*/

@description('Name of the existing APIM instance')
param apimName string

@description('API path (also used as the API name), e.g. "mcp"')
param apiPath string = 'mcp'

@description('FQDN of the MCP web app (private endpoint), e.g. mcp-xxxx.azurewebsites.net')
param mcpWebAppFqdn string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

var backendId = 'mcp-server-backend'
var backendBaseUrl = 'https://${mcpWebAppFqdn}'

// First-class backend for the MCP web app (private endpoint).
resource mcpBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: backendId
  properties: {
    title: 'MCP Server (App Service PE)'
    description: 'Private MCP web app reached via APIM outbound VNet integration -> firewall -> App Service spoke PE.'
    protocol: 'http'
    url: backendBaseUrl
  }
}

// MCP-type API — requires preview API version for type:'mcp' and mcpProperties.
// The union() workaround merges standard API properties with MCP-specific properties
// that are not yet in the published Bicep type definitions.
resource mcpApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: apiPath
  properties: union({
    displayName: 'MCP Server Gateway'
    description: 'Enterprise MCP server exposed through the APIM AI gateway. Proxies to the private MCP web app with pass-through AgenticIdentityToken auth.'
    path: apiPath
    protocols: [
      'https'
    ]
    // Keyless: the Foundry MCP connection authenticates with the AgenticIdentityToken
    // (Entra JWT). No APIM subscription key is sent — the connection cannot present both.
    subscriptionRequired: false
  }, {
    type: 'mcp'
    backendId: mcpBackend.name
    mcpProperties: {
      endpoints: {
        mcp: {
          uriTemplate: '/'
        }
      }
    }
  })
}

output apiName string = mcpApi.name
output apiPath string = apiPath
@description('Full MCP server URL through the APIM gateway, e.g. https://<apim>.azure-api.net/mcp')
output mcpGatewayUrl string = '${apim.properties.gatewayUrl}/${apiPath}'
