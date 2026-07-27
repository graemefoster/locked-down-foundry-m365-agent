/*
Stage 20 slice — MCP web app (leaf).
The private MCP function web app + its user-assigned managed identity (MI-as-FIC
subject for the guarding Entra app registration) + diagnostics. Runs on the shared
App Service plan created in stage 10 (referenced here as an existing serverfarm so
its resource id is byte-identical to the stage-10 declaration).
*/

param location string
param appInsightsName string
param appServiceDelegationSubnetId string
param aspName string
param logAnalyticsId string

resource aspTest 'Microsoft.Web/serverfarms@2022-09-01' existing = {
  name: aspName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

// User-assigned identity for the MCP web app. Used as a federated credential (MI-as-FIC) so
// App Service built-in auth can act as the Entra app registration WITHOUT a client secret —
// see builtin-auth.bicep + app-registration.bicep. The identity's clientId is surfaced to
// EasyAuth via the magic OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID app setting below.
resource mcpIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-mcp-${aspName}'
  location: location
}

resource mcpWebApp 'Microsoft.Web/sites@2025-03-01' = {
  name: 'mcp-${aspName}'
  location: location
  kind: 'app,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${mcpIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: aspTest.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|docker.io/graemefoster/my-mcp-function-webapp:0.9'
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'ASPNETCORE_ENVIRONMENT'
          value: 'Production'
        }
        // Magic setting: tells App Service built-in auth to authenticate as the app
        // registration using this managed identity as a federated credential (no secret).
        {
          name: 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID'
          value: mcpIdentity.properties.clientId
        }
      ]
      publicNetworkAccess: 'Disabled'
    }
    httpsOnly: true
    virtualNetworkSubnetId: appServiceDelegationSubnetId
    outboundVnetRouting: {
      allTraffic: true
    }
  }
}

resource mcpAppDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: mcpWebApp
  name: 'diagnostics'
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output mcpWebAppName string = mcpWebApp.name
output mcpWebAppFqdn string = mcpWebApp.properties.defaultHostName
// MI-as-FIC wiring for the MCP web app's built-in auth (see app-registration.bicep).
output mcpWebAppIdentityPrincipalId string = mcpIdentity.properties.principalId
output mcpWebAppIdentityClientId string = mcpIdentity.properties.clientId
