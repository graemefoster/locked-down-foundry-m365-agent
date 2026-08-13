/*
Foundry (Azure AI Services) account — the core resource of the whole platform.

Despite living under foundry/, this creates the ENTIRE account, not just an identity:
  - the Microsoft.CognitiveServices/accounts resource ('AIServices' kind) that IS Foundry
  - a model deployment on it (the default chat model)
  - a system-assigned managed identity (the account's data-plane identity)
  - VNet injection into the agent subnet (so the account runs inside the private network)
  - diagnostic settings -> Log Analytics / App Insights

The CMK re-PUT of this account lives in encryption/ai-account-encryption.bicep; both must
agree on the egress posture, so restrictOutboundNetworkAccess / allowedFqdnList are threaded
in from the stage orchestrator rather than defaulted here.
*/

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

@description('Restrict outbound network access to the allowedFqdnList. Shared with the CMK encryption module so both declarations of the account agree (a CognitiveServices update is a full PUT).')
param restrictOutboundNetworkAccess bool

@description('Allowed outbound FQDNs (only enforced when restrictOutboundNetworkAccess is true). Shared with the CMK encryption module.')
param allowedFqdnList array

@description('Public network access on the Foundry account data plane. Disabled = private-endpoint-only (firewall tier); Enabled = reachable publicly (firewall opt-out on-ramp, PE still present). Shared with the CMK encryption module so both full-PUT declarations agree.')
param publicNetworkAccess string = 'Disabled'

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
    publicNetworkAccess: publicNetworkAccess

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
    restrictOutboundNetworkAccess: restrictOutboundNetworkAccess //to further restrict tool calls to specific endpoints, set to true then populate allowedFqdnList
    allowedFqdnList: allowedFqdnList
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
