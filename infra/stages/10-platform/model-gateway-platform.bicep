/*
Stage 10 slice — Model gateway platform + MCP gateway wiring.

The always-on enterprise model gateway substrate: the locked-down "provider"
Foundry that hosts the gateway model, the APIM Standard v2 instance, APIM's
inbound private endpoint, the provider Foundry private endpoints and the APIM->
provider role assignment.

It ALSO hosts the MCP gateway wiring that used to sit in main.bicep — the Entra
app registration guarding the MCP web app and the APIM MCP server APIs — because
the primary Foundry project (project slice) consumes the resulting
`mcpConnections` array. Keeping the app-registration + MCP-server modules here
(rather than in main) is what avoids a stage<->main dependency cycle: main's
apimMcpServers/mcpAppRegistration would otherwise need this stage's apim/web-app
outputs while this stage needs their `mcpConnections` output.
*/

param location string
param uniqueSuffix string

// Provider Foundry + gateway-exposed model.
param providerAccountName string
param gatewayModelName string
param gatewayModelFormat string
param gatewayModelVersion string
param gatewayModelSkuName string
param gatewayModelCapacity int

param apimName string

// From stage 00.
param logAnalyticsId string
param appInsightsId string
param appInsightsConnectionString string
param modelGatewayApimSubnetId string
param modelGatewayPeSubnetId string
param hubVnetId string

// From the data-resources slice (MCP web app).
param mcpWebAppFqdn string
param mcpWebAppIdentityPrincipalId string

// Provider AI Foundry (the "real" model provider) — minimal, locked-down.
module providerFoundry '../../modules/model-gateway/provider-foundry.bicep' = {
  name: 'provider-foundry-${uniqueSuffix}-deployment'
  params: {
    accountName: providerAccountName
    location: location
    modelName: gatewayModelName
    modelFormat: gatewayModelFormat
    modelVersion: gatewayModelVersion
    modelSkuName: gatewayModelSkuName
    modelCapacity: gatewayModelCapacity
    logAnalyticsWorkspaceId: logAnalyticsId
  }
}

// APIM Standard v2 in the gateway spoke. ALWAYS deployed (shared gateway).
module apim '../../modules/model-gateway/apim.bicep' = {
  name: 'model-gateway-apim-${uniqueSuffix}-deployment'
  params: {
    apimName: apimName
    location: location
    apimOutboundSubnetId: modelGatewayApimSubnetId
    logAnalyticsWorkspaceId: logAnalyticsId
    appInsightsResourceId: appInsightsId
    appInsightsConnectionString: appInsightsConnectionString
  }
}

// APIM inbound private endpoint + privatelink.azure-api.net DNS. ALWAYS deployed:
// callers (model-gateway connection AND the Teams inbound YARP path) reach APIM only
// through this PE once apim-lockdown flips publicNetworkAccess to 'Disabled'.
module apimPrivateEndpoint '../../modules/model-gateway/apim-private-endpoint.bicep' = {
  name: 'apim-pe-${uniqueSuffix}-deployment'
  params: {
    location: location
    suffix: uniqueSuffix
    apimId: apim.outputs.apimId
    apimName: apim.outputs.apimName
    peSubnetId: modelGatewayPeSubnetId
    hubVnetId: hubVnetId
  }
}

// Provider Foundry private endpoint + DNS in the gateway spoke (model gateway only).
module modelGatewayPrivateEndpoints '../../modules/model-gateway/model-gateway-private-endpoints.bicep' = {
  name: 'model-gateway-pe-${uniqueSuffix}-deployment'
  params: {
    location: location
    providerAccountId: providerFoundry.outputs.accountId
    providerAccountName: providerFoundry.outputs.accountName
    peSubnetId: modelGatewayPeSubnetId
  }
}

// Grant APIM MI Cognitive Services User on the provider Foundry (backend MI auth).
module apimProviderRoleAssignment '../../modules/model-gateway/apim-provider-role-assignment.bicep' = {
  name: 'model-gateway-apim-rbac-${uniqueSuffix}-deployment'
  params: {
    providerAccountName: providerFoundry.outputs.accountName
    apimPrincipalId: apim.outputs.apimPrincipalId
  }
}

/*
  Entra app registration guarding the private MCP web app. Federated to the MCP web app's
  user-assigned managed identity (MI-as-FIC) so App Service built-in auth is secretless.
*/
module mcpAppRegistration '../../modules/gateway/app-registration.bicep' = {
  name: 'mcp-appreg-${uniqueSuffix}-deployment'
  params: {
    clientAppName: 'mcp-gateway-${uniqueSuffix}'
    clientAppDisplayName: 'MCP Gateway (${uniqueSuffix})'
    webAppIdentityPrincipalId: mcpWebAppIdentityPrincipalId
  }
}

// APIM MCP server APIs — exposes each private MCP web app in mcp/mcp.json through the APIM
// gateway. The Foundry MCP connection points at these APIM endpoints instead of directly at
// the App Service private endpoints, so all MCP tool traffic flows through the gateway.
// Backend FQDNs are generated at provision time, so they are NOT stored in mcp/mcp.json — they
// are flowed in here, keyed by server name. The existing sample is the server named 'mcp'.
var mcpServerFqdns = {
  mcp: mcpWebAppFqdn
}
module apimMcpServers '../../modules/model-gateway/apim-mcp-servers.bicep' = {
  name: 'mcp-apim-servers-${uniqueSuffix}-deployment'
  params: {
    apimName: apim.outputs.apimName
    serverFqdns: mcpServerFqdns
  }
  dependsOn: [
    apimProviderRoleAssignment
  ]
}
// One Foundry project connection per governed MCP server: connection name from mcp/mcp.json
// (via the module output), target = that server's APIM gateway URL, audience = the shared MCP
// app registration audience (per-server audiences would slot in here later). Building this from
// the module output (a single map, no nested lambda) means there is no "primary server" to
// special-case — every server is wired symmetrically, and aiProject consumes the whole array.
var mcpConnections = map(apimMcpServers.outputs.servers, srv => {
  name: srv.connectionName
  url: '${srv.url}/'
  audience: mcpAppRegistration.outputs.audience
})
// URL of the sample MCP server (the first configured server) that the deploy-test-agent-one
// workflow injects as test-agent-one's `server_url`. first() is safe: mcp/mcp.json always has >=1
// server, and the sample 'mcp' server is the first entry by convention.
var mcpSampleGatewayUrl = '${first(apimMcpServers.outputs.servers).url}/'

// Model gateway
output providerAccountId string = providerFoundry.outputs.accountId
output apimName string = apim.outputs.apimName
output gatewayUrl string = apim.outputs.gatewayUrl

// MCP gateway wiring (consumed by the project slice + surviving main modules)
output mcpConnections array = mcpConnections
output mcpSampleGatewayUrl string = mcpSampleGatewayUrl
output mcpClientAppId string = mcpAppRegistration.outputs.clientAppId
output mcpIssuer string = mcpAppRegistration.outputs.issuer
output mcpAudience string = mcpAppRegistration.outputs.audience
