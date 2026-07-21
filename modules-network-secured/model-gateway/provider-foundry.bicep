/*
  Model-Gateway: Provider AI Foundry (the "real" model provider)
  --------------------------------------------------------------
  A locked-down Cognitive Services / AIServices account that actually hosts the
  model. It is NOT the primary agent Foundry — it sits behind APIM in the
  model-gateway spoke. Public network access is disabled; APIM reaches it over a
  private endpoint (created in model-gateway-private-endpoints.bicep) and
  authenticates with APIM's own managed identity (Cognitive Services OpenAI User).

  Kept intentionally simple: system-assigned MI + a single model deployment.
  No agent networkInjection, no project — this account only serves inference.
*/

param accountName string
param location string

@description('Name of the model to deploy and expose through the gateway')
param modelName string = 'gpt-5.4-mini'
param modelFormat string = 'OpenAI'
param modelVersion string
param modelSkuName string = 'GlobalStandard'
param modelCapacity int = 30

param logAnalyticsWorkspaceId string

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
    customSubDomainName: accountName
    networkAcls: {
      defaultAction: 'Deny'
      virtualNetworkRules: []
      ipRules: []
      bypass: 'AzureServices'
    }
    publicNetworkAccess: 'Disabled'
    // Entra-only: APIM authenticates to this backend via its managed identity.
    disableLocalAuth: true
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

resource providerDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
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
output accountId string = account.id
output accountPrincipalId string = account.identity.principalId
output accountEndpoint string = account.properties.endpoint
output modelDeploymentName string = modelDeployment.name
