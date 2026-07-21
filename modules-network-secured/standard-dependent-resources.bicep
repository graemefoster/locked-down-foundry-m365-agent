// Creates Azure dependent resources for Azure AI Agent Service standard agent setup

@description('Azure region of the deployment')
param location string

@description('The name of the AI Search resource')
param aiSearchName string

@description('Name of the storage account')
param azureStorageName string

@description('Name of the new Cosmos DB account')
param cosmosDBName string

@description('The AI Search Service full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param aiSearchResourceId string

@description('The AI Storage Account full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param azureStorageAccountResourceId string

@description('The Cosmos DB Account full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param cosmosDBResourceId string

// param aiServiceExists bool
param aiSearchExists bool
param azureStorageExists bool
param cosmosDBExists bool
param logAnalyticsId string
param appServicePlanName string
param appInsightsName string
param appServiceDelegationSubnetId string
param foundryName string

var cosmosParts = split(cosmosDBResourceId, '/')

resource existingCosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = if (cosmosDBExists) {
  name: cosmosParts[8]
  scope: resourceGroup(cosmosParts[2], cosmosParts[4])
}

// CosmosDB creation

var canaryRegions = ['eastus2euap', 'centraluseuap']
var cosmosDbRegion = contains(canaryRegions, location) ? 'westus' : location
resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = if (!cosmosDBExists) {
  name: cosmosDBName
  location: cosmosDbRegion
  kind: 'GlobalDocumentDB'
  properties: {
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    disableLocalAuth: true
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false
    publicNetworkAccess: 'Disabled'
    networkAclBypass: 'AzureServices'
    enableFreeTier: false
    ipRules: [
      {
        ipAddressOrRange: '49.192.23.85' //Graeme's IP!
      }
      {
        ipAddressOrRange: '4.210.172.107' //azure portal
      }
      {
        ipAddressOrRange: '13.88.56.148' //azure portal
      }
      {
        ipAddressOrRange: '13.91.105.215' //azure portal
      }
      {
        ipAddressOrRange: '40.91.218.243' //azure portal
      }
    ]
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    databaseAccountOfferType: 'Standard'
  }
}

resource cosmosDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: cosmosDB
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

var acsParts = split(aiSearchResourceId, '/')

resource existingSearchService 'Microsoft.Search/searchServices@2024-06-01-preview' existing = if (aiSearchExists) {
  name: acsParts[8]
  scope: resourceGroup(acsParts[2], acsParts[4])
}

// AI Search creation

resource aiSearch 'Microsoft.Search/searchServices@2025-05-01' = if (!aiSearchExists) {
  name: aiSearchName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    disableLocalAuth: false
    authOptions: { aadOrApiKey: { aadAuthFailureMode: 'http401WithBearerChallenge' } }
    encryptionWithCmk: {
      enforcement: 'Enabled'
    }
    hostingMode: 'Default'
    partitionCount: 1
    publicNetworkAccess: 'Disabled'
    replicaCount: 1
    semanticSearch: 'disabled'
    networkRuleSet: {
      bypass: 'AzureServices'
    }
  }
  sku: {
    name: 'basic'
  }
}

resource searchDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: aiSearch
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

var azureStorageParts = split(azureStorageAccountResourceId, '/')

resource existingAzureStorageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = if (azureStorageExists) {
  name: azureStorageParts[8]
  scope: resourceGroup(azureStorageParts[2], azureStorageParts[4])
}

// Some regions doesn't support Standard Zone-Redundant storage, need to use Geo-redundant storage
param noZRSRegions array = ['southindia', 'westus', 'northcentralus']
param sku object = contains(noZRSRegions, location) ? { name: 'Standard_GRS' } : { name: 'Standard_ZRS' }

// Storage creation

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = if (!azureStorageExists) {
  name: azureStorageName
  location: location
  kind: 'StorageV2'
  sku: sku
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    allowSharedKeyAccess: false
  }
}

resource blob 'Microsoft.Storage/storageAccounts/blobServices@2021-09-01' existing = {
  name: 'default'
  parent: storage
}

resource queue 'Microsoft.Storage/storageAccounts/queueServices@2025-06-01' existing = {
  name: 'default'
  parent: storage

  resource AgentInputQueue 'queues' = {
    name: 'inputqueuetest'
  }

  resource AgentOutputQueue 'queues' = {
    name: 'outputqueuetest'
  }
}

resource blobSetting 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'blobDiagnostics'
  scope: blob
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      {
        category: 'StorageRead'
        enabled: true
      }
      {
        category: 'StorageWrite'
        enabled: true
      }
      {
        category: 'StorageDelete'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}


resource queueSetting 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'queueDiagnostics'
  scope: queue
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      // {
      //   category: 'allLogs'
      //   enabled: true
      // }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

module appService './app-service.bicep' = {
  name: 'appServiceDeployment'
  params: {
    location: location
    logAnalyticsId: logAnalyticsId
    aspName: appServicePlanName
    appInsightsName: appInsightsName
    appServiceDelegationSubnetId: appServiceDelegationSubnetId
    storageName: azureStorageExists ? existingAzureStorageAccount.name : storage.name
    foundryName: foundryName
  }
}

output aiSearchName string = aiSearchExists ? existingSearchService.name : aiSearch.name
output aiSearchID string = aiSearchExists ? existingSearchService.id : aiSearch.id
output aiSearchServiceResourceGroupName string = aiSearchExists ? acsParts[4] : resourceGroup().name
output aiSearchServiceSubscriptionId string = aiSearchExists ? acsParts[2] : subscription().subscriptionId

output azureStorageName string = azureStorageExists ? existingAzureStorageAccount.name : storage.name
output azureStorageId string = azureStorageExists ? existingAzureStorageAccount.id : storage.id
output azureStorageResourceGroupName string = azureStorageExists ? azureStorageParts[4] : resourceGroup().name
output azureStorageSubscriptionId string = azureStorageExists ? azureStorageParts[2] : subscription().subscriptionId

output cosmosDBName string = cosmosDBExists ? existingCosmosDB.name : cosmosDB.name
output cosmosDBId string = cosmosDBExists ? existingCosmosDB.id : cosmosDB.id
output cosmosDBResourceGroupName string = cosmosDBExists ? cosmosParts[4] : resourceGroup().name
output cosmosDBSubscriptionId string = cosmosDBExists ? cosmosParts[2] : subscription().subscriptionId
// output keyvaultId string = keyVault.id

output appServicePlanId string = appService.outputs.aspId
output yarpWebAppName string = appService.outputs.yarpWebAppName
output mcpWebAppName string = appService.outputs.mcpWebAppName
output yarpWebAppFqdn string = appService.outputs.yarpWebAppFqdn
output mcpWebAppFqdn string = appService.outputs.mcpWebAppFqdn

output storagePrincipalId string = !azureStorageExists ? storage.identity.principalId : ''
output aiSearchPrincipalId string = !aiSearchExists ? aiSearch.identity.principalId : ''

