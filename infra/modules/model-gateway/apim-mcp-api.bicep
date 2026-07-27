/*
  Model-Gateway: APIM MCP server API (one server)
  ------------------------------------------------
  Exposes ONE private MCP web app (App Service) through APIM as a first-class
  MCP-type API. The Foundry MCP connection points at this APIM endpoint instead
  of directly at the App Service private endpoint, so all MCP traffic flows
  through the enterprise model gateway. apim-mcp-servers.bicep instantiates this
  module once per entry in mcp/mcp.json.

  CONVENTION-DRIVEN: everything is derived from the server `name` - the APIM API
  name + path are `<name>`, and the backend path defaults to `/<name>`. Nothing
  about routing is hardcoded; the previously hardcoded `mcp` default now lives in
  mcp/mcp.json as a server name (retrofitting the already-deployed sample, whose
  backend is served at /mcp).

  Auth posture: pass-through. The Foundry agent presents an AgenticIdentityToken
  (Entra JWT minted for the MCP app registration's audience). APIM forwards it
  unchanged to the MCP web app backend, where App Service built-in auth validates
  it. No APIM subscription key is required (subscriptionRequired = false) and
  APIM does NOT swap the token - the original Authorization header is preserved.

  The backend is the MCP web app's private endpoint, reached by APIM outbound
  VNet integration -> firewall -> App Service spoke pe-subnet.

  Uses the preview API version (2024-06-01-preview) for `type: 'mcp'` and
  `mcpProperties` support.
*/

@description('Name of the existing APIM instance')
param apimName string

@description('MCP server name. Used verbatim as the APIM API name + path, and (by convention) as the backend path.')
param serverName string

@description('FQDN of the MCP web app (private endpoint), e.g. mcp-xxxx.azurewebsites.net. Flowed in dynamically from the deployment (see main.bicep serverFqdns) - never stored in mcp/mcp.json.')
param mcpWebAppFqdn string

@description('Path on the backend MCP web app where the streamable-HTTP MCP endpoint is served. Defaults to /<serverName> by convention.')
param backendPath string = '/${serverName}'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// Backend id is namespaced by server so multiple MCP servers never collide.
var backendId = 'mcp-server-backend-${serverName}'
// The backend MCP container (Express) serves the streamable-HTTP MCP endpoint at its path, NOT at
// root. APIM's type:mcp proxy forwards the MCP protocol to the backend `url` verbatim (it does
// NOT append the endpoint uriTemplate), so the backend url MUST include the path - with a bare
// host url APIM hits backend root and the server returns 404 (Cannot POST /).
var backendBaseUrl = 'https://${mcpWebAppFqdn}${backendPath}'

// First-class backend for the MCP web app (private endpoint).
resource mcpBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: backendId
  properties: {
    title: 'MCP Server (${serverName}) - App Service PE'
    description: 'Private MCP web app reached via APIM outbound VNet integration -> firewall -> App Service spoke PE.'
    protocol: 'http'
    url: backendBaseUrl
  }
}

// MCP-type API - requires preview API version for type:'mcp' and mcpProperties.
// The union() workaround merges standard API properties with MCP-specific properties
// that are not yet in the published Bicep type definitions.
resource mcpApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: serverName
  properties: union({
    displayName: 'MCP Server Gateway (${serverName})'
    description: 'Enterprise MCP server exposed through the APIM AI gateway. Proxies to the private MCP web app with pass-through AgenticIdentityToken auth.'
    path: serverName
    protocols: [
      'https'
    ]
    // Keyless: the Foundry MCP connection authenticates with the AgenticIdentityToken
    // (Entra JWT). No APIM subscription key is sent - the connection cannot present both.
    subscriptionRequired: false
  }, {
    type: 'mcp'
    backendId: mcpBackend.name
    mcpProperties: {
      endpoints: {
        mcp: {
          // The MCP endpoint's backend path lives in the backend `url` (see backendBaseUrl),
          // which already includes the path. Keep this at root so APIM does not double the path.
          uriTemplate: '/'
        }
      }
    }
  })
}

output apiName string = mcpApi.name
output apiPath string = serverName
@description('Full MCP server URL through the APIM gateway, e.g. https://<apim>.azure-api.net/<serverName>')
output mcpGatewayUrl string = '${apim.properties.gatewayUrl}/${serverName}'
