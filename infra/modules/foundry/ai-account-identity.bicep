param accountName string
param location string
param modelName string
param modelFormat string
param modelVersion string
param modelSkuName string
param modelCapacity int
param agentSubnetId string
param networkInjection string = 'true'
param logAnalyticsWorkspaceId string
param mcpServerName string
param keyVaultName string = ''

@secure()
param appInsightsConnectionString string
param appInsightsResourceId string

#disable-next-line BCP036
resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: accountName
  location: location
  sku: {
    name: 'S0'
  }
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    networkAcls: {
      defaultAction: 'Allow'
      virtualNetworkRules: []
      ipRules: []
      bypass: 'AzureServices'
    }
    publicNetworkAccess: 'Disabled'

    networkInjections: ((networkInjection == 'true')
      ? [
          {
            scenario: 'agent'
            subnetArmId: agentSubnetId
            useMicrosoftManagedNetwork: false
          }
        ]
      : null)
    // Set disable local auth to true or false. Agent service does not support API key based authentication
    disableLocalAuth: false
    restrictOutboundNetworkAccess: false //to further restrict tool calls to specific endpoints, set to true then use the allowedFqdnList property
    allowedFqdnList: empty(keyVaultName) ? [] : [
      '${keyVaultName}.vault.azure.net'
    ]
  }

  //wire up app-insights
  resource appInsights 'connections@2025-10-01-preview' = {
    name: 'appInsightsConnection'
    properties: {
      category: 'AppInsights'

      target: appInsightsResourceId
      authType: 'ApiKey'
      credentials: {
        key: appInsightsConnectionString
      }
      useWorkspaceManagedIdentity: false
      isSharedToAll: false
      metadata: {
        ApiType: 'Azure'
        ResourceId: appInsightsResourceId
      }
    }
  }
}

#disable-next-line BCP081
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: account
  name: modelName
  sku: {
    capacity: modelCapacity
    name: modelSkuName
  }
  properties: {
    model: {
      name: modelName
      format: modelFormat
      version: modelVersion
    }
  }
}

resource foundryDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: account
  name: 'diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output accountName string = account.name
output accountID string = account.id
output accountTarget string = account.properties.endpoint
output accountPrincipalId string = account.identity.principalId
// The Foundry Agents API lives on services.ai.azure.com, not cognitiveservices.azure.com
#disable-next-line BCP053
output foundryApiEndpoint string = account.properties.endpoints['AI Foundry API']
