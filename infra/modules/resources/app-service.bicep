param location string
param logAnalyticsId string
param appInsightsName string
param appServiceDelegationSubnetId string
param aspName string
param storageName string
param foundryName string

@description('When true, the YARP proxy is flipped PUBLIC (Teams/M365 inbound entry point), reverse-proxies to the APIM Teams API instead of Foundry directly, and inbound is IP-restricted to the AzureBotService service tag.')
param enableTeamsPublish bool = false

@description('APIM gateway base URL (e.g. https://apim-xxx.azure-api.net) the YARP proxy forwards Teams traffic to. Only used when enableTeamsPublish=true.')
param apimGatewayUrl string = ''

@description('App Service access-restriction service tag allowed to reach the public YARP proxy inbound (Bot Channel Adapter).')
param botChannelServiceTag string = 'AzureBotService'

// Teams inbound: YARP is the public messaging entry point and forwards to the APIM Teams
// API (which validates the Bot Framework JWT and forwards to the agent activityProtocol
// endpoint). Otherwise it stays private and reverse-proxies to Foundry directly (legacy).
var yarpPublicNetworkAccess = enableTeamsPublish ? 'Enabled' : 'Disabled'
var yarpReverseProxyAddress = enableTeamsPublish
  ? '${apimGatewayUrl}/'
  : 'https://${foundryName}.services.ai.azure.com/'
var yarpIpRestrictions = enableTeamsPublish
  ? [
      {
        ipAddress: botChannelServiceTag
        tag: 'ServiceTag'
        action: 'Allow'
        priority: 100
        name: 'AllowAzureBotService'
        description: 'Azure Bot Service channel adapters only (public YARP endpoint).'
      }
    ]
  : []

resource storage 'Microsoft.Storage/storageAccounts@2025-06-01' existing = {
  name: storageName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource aspTest 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: aspName
  location: location
  sku: {
    name: 'P0V3'
    capacity: 1
  }
  properties: {
    zoneRedundant: false
    //make it linux
    reserved: true
  }
}

//and one web-app where we will deploy the YARP proxy to later
resource webApp 'Microsoft.Web/sites@2025-03-01' = {
  name: 'yarp-${aspName}'
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: aspTest.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|docker.io/graemefoster/teams-proxy:0.3'
      publicNetworkAccess: yarpPublicNetworkAccess
      ipSecurityRestrictionsDefaultAction: enableTeamsPublish ? 'Deny' : 'Allow'
      ipSecurityRestrictions: yarpIpRestrictions
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'ReverseProxy__Clusters__cluster1__Destinations__destination1__Address'
          value: yarpReverseProxyAddress
        }
      ]
    }
    httpsOnly: true
    virtualNetworkSubnetId: appServiceDelegationSubnetId
    outboundVnetRouting: {
      allTraffic: true
    }
  }
}

resource mcpWebApp 'Microsoft.Web/sites@2025-03-01' = {
  name: 'mcp-${aspName}'
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: aspTest.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|docker.io/graemefoster/my-mcp-function-webapp:0.7'
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'ASPNETCORE_ENVIRONMENT'
          value: 'Production'
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


resource appDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: webApp
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


output aspId string = aspTest.id
output yarpWebAppFqdn string = webApp.properties.defaultHostName
output yarpWebAppName string = webApp.name
output mcpWebAppName string = mcpWebApp.name
output mcpWebAppFqdn string = mcpWebApp.properties.defaultHostName
