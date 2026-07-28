/*
Stage 20 — Workload: MCP (orchestrator)

The governed MCP workload on top of the stage 10 platform. Composes the leaves —
  mcp-web-app.bicep                      → private MCP web app + MI-as-FIC identity
  network/app-service-private-endpoint   → MCP web app private endpoint + DNS
  gateway/app-registration.bicep         → Entra app registration (MI-as-FIC) guarding it
  model-gateway/apim-mcp-servers.bicep   → APIM MCP server API(s) fronting the web app
  gateway/builtin-auth.bicep             → App Service built-in auth (EasyAuth) on the web app

Consumes stage 00 networking/observability + the stage 10 APIM name; re-exposes the
APIM MCP servers array + the app-registration audience that main.bicep wires into the
Foundry project MCP connections and the APIM MCP compliance policy.
*/

param location string
param uniqueSuffix string
param appServicePlanName string
param appInsightsName string
param appServiceDelegatedSubnetId string
param logAnalyticsId string
param appServiceSpokeVnetName string
param appServicePeSubnetName string
param appServiceDnsZoneId string
param apimName string

module mcpWebApp 'mcp-web-app.bicep' = {
  name: 'stage20-mcp-web-app-${uniqueSuffix}'
  params: {
    location: location
    appInsightsName: appInsightsName
    appServiceDelegationSubnetId: appServiceDelegatedSubnetId
    aspName: appServicePlanName
    logAnalyticsId: logAnalyticsId
  }
}

// The YARP proxy is the public ingress (its own FQDN + managed cert is the Bot Channel
// Adapter entry point), so it gets NO private endpoint — only the MCP web app does.
module appServicePrivateEndpoint './network/app-service-private-endpoint.bicep' = {
  name: 'stage20-mcp-private-endpoint-${uniqueSuffix}'
  params: {
    appServiceSpokeVnetName: appServiceSpokeVnetName
    appServicePeSubnetName: appServicePeSubnetName
    appServiceWebAppNames: [mcpWebApp.outputs.mcpWebAppName]
    appServiceDnsZoneId: appServiceDnsZoneId
  }
}

/*
  Entra app registration guarding the private MCP web app. Federated to the MCP web app's
  user-assigned managed identity (MI-as-FIC) so App Service built-in auth is secretless.
*/
module mcpAppRegistration './gateway/app-registration.bicep' = {
  name: 'mcp-appreg-${uniqueSuffix}-deployment'
  params: {
    clientAppName: 'mcp-gateway-${uniqueSuffix}'
    clientAppDisplayName: 'MCP Gateway (${uniqueSuffix})'
    webAppIdentityPrincipalId: mcpWebApp.outputs.mcpWebAppIdentityPrincipalId
  }
}

// APIM MCP server APIs — exposes each private MCP web app in mcp/mcp.json through the APIM
// gateway. The Foundry MCP connection points at these APIM endpoints instead of directly at
// the App Service private endpoints, so all MCP tool traffic flows through the gateway.
// Backend FQDNs are generated at provision time, so they are NOT stored in mcp/mcp.json — they
// are flowed in here, keyed by server name. The existing sample is the server named 'mcp'.
module apimMcpServers './model-gateway/apim-mcp-servers.bicep' = {
  name: 'mcp-apim-servers-${uniqueSuffix}-deployment'
  params: {
    apimName: apimName
    serverFqdns: {
      mcp: mcpWebApp.outputs.mcpWebAppFqdn
    }
  }
}

/*
  App Service built-in auth (EasyAuth) on the MCP web app — returns 401 on unauthenticated
  requests (machine-to-machine, no interactive redirect) and validates the AgenticIdentityToken
  audience against the app registration's Application ID URI.
*/
module mcpBuiltinAuth './gateway/builtin-auth.bicep' = {
  name: 'mcp-auth-${uniqueSuffix}-deployment'
  params: {
    appServiceName: mcpWebApp.outputs.mcpWebAppName
    clientId: mcpAppRegistration.outputs.clientAppId
    issuer: mcpAppRegistration.outputs.issuer
    allowedAudience: mcpAppRegistration.outputs.audience
  }
}

output servers array = apimMcpServers.outputs.servers
output mcpAudience string = mcpAppRegistration.outputs.audience
