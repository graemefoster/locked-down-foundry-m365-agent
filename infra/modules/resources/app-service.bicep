param location string
param logAnalyticsId string
param appInsightsName string
param appServiceDelegationSubnetId string
param aspName string
param storageName string
param foundryName string

@description('When true, the YARP proxy is flipped PUBLIC (Teams/M365 inbound entry point), reverse-proxies to the APIM Teams API instead of Foundry directly, and inbound is IP-restricted to the Microsoft Teams "Required" published IP ranges.')
param enableTeamsPublish bool = false

@description('APIM gateway base URL (e.g. https://apim-xxx.azure-api.net) the YARP proxy forwards Teams traffic to. Only used when enableTeamsPublish=true.')
param apimGatewayUrl string = ''

// Microsoft Teams "Required" published IP ranges — the source ranges the Bot Channel Adapter
// uses to POST activities to the messaging endpoint. From the Microsoft 365 URLs & IP address
// ranges list, service area "Skype" / display name "Microsoft Teams" (endpoint sets 11-12).
// NOT the AzureBotService service tag: that tag covers DirectLine + the Bot Service token
// cache, which this Teams-channel delivery path does not use, and it does NOT include the
// 52.112.0.0/14 / 52.122.0.0/15 ranges the adapter actually connects from.
// Source: https://learn.microsoft.com/microsoft-365/enterprise/urls-and-ip-address-ranges
// (refresh via https://endpoints.office.com/endpoints/worldwide — serviceArea == 'Skype', required == true)
var teamsInboundIpRanges = [
  '52.112.0.0/14'
  '52.122.0.0/15'
  '2603:1027::/48'
  '2603:1037::/48'
  '2603:1047::/48'
  '2603:1057::/48'
  '2603:1063::/38'
  '2620:1ec:40::/42'
  '2620:1ec:6::/48'
]

// Teams inbound: YARP is the public messaging entry point and forwards to the APIM Teams
// API (which validates the Bot Framework JWT and forwards to the agent activityProtocol
// endpoint). Otherwise it stays private and reverse-proxies to Foundry directly (legacy).
var yarpPublicNetworkAccess = enableTeamsPublish ? 'Enabled' : 'Disabled'
var yarpReverseProxyAddress = enableTeamsPublish
  ? '${apimGatewayUrl}/'
  : 'https://${foundryName}.services.ai.azure.com/'
var teamsInboundIpRules = [
  for (cidr, i) in teamsInboundIpRanges: {
    ipAddress: cidr
    action: 'Allow'
    priority: 100 + i
    name: 'AllowTeamsInbound-${i}'
    description: 'Microsoft Teams Required inbound range'
  }
]
var yarpIpRestrictions = enableTeamsPublish ? teamsInboundIpRules : []

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
