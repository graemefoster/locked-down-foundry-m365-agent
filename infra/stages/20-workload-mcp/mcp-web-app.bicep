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

resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' existing = {
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
  // azd maps the MCP service (azure.yaml: mcp) to this web app via this tag, then builds
  // agent-tools locally and zip-deploys it (no container image).
  tags: {
    'azd-service-name': 'mcp'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${mcpIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      // Node code stack (was a DOCKER image). Source lives in mcp/agent-tools; azd zip-deploys it
      // and App Service runs `npm start` (ts-node src/index.ts).
      linuxFxVersion: 'NODE|22-lts'
      appCommandLine: 'node index.js'
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
        // node_modules are built on the azd host and shipped in the zip, so Kudu must NOT rebuild
        // (the app's outbound traffic is VNet-routed through a deny-by-default firewall = no npm).
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'false'
        }
        // Magic setting: tells App Service built-in auth to authenticate as the app
        // registration using this managed identity as a federated credential (no secret).
        {
          name: 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID'
          value: mcpIdentity.properties.clientId
        }
      ]
      // Fully private at rest (private endpoint only). The predeploy hook temporarily enables
      // public access + allows the deployer IP through the SCM site so azd can zip-deploy, then
      // the postdeploy hook re-disables it. Deny-by-default on the SCM site is belt-and-braces
      // for the deploy window.
      publicNetworkAccess: 'Disabled'
      scmIpSecurityRestrictionsUseMain: false
      scmIpSecurityRestrictionsDefaultAction: 'Deny'
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
