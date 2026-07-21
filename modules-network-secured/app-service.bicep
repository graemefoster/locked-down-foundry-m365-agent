param location string
param logAnalyticsId string
param appInsightsName string
param appServiceDelegationSubnetId string
param aspName string
param storageName string
param foundryName string

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
      publicNetworkAccess: 'Disabled'
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'ReverseProxy__Clusters__cluster1__Destinations__destination1__Address'
          value: 'https://${foundryName}.services.ai.azure.com/'
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
