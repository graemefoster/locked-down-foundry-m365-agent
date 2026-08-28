// Creates the bring-your-own agent-state stores for the Azure AI Agent Service STANDARD tier:
// CosmosDB (threads), AI Search (vectors) and Storage (files). Gated as a unit by
// deployStandardAgent in the caller — the BASIC tier deploys none of this.

@description('Azure region of the deployment')
param location string

@description('The name of the AI Search resource')
param aiSearchName string

@description('Name of the storage account')
param azureStorageName string

@description('Name of the new Cosmos DB account')
param cosmosDBName string

param logAnalyticsId string

// Private-endpoint-only data plane: public network access is always disabled.
var dataPlanePublicNetworkAccess = 'Disabled'

// CosmosDB creation

var canaryRegions = ['eastus2euap', 'centraluseuap']
var cosmosDbRegion = contains(canaryRegions, location) ? 'westus' : location
resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
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
    publicNetworkAccess: dataPlanePublicNetworkAccess
    networkAclBypass: 'AzureServices'
    enableFreeTier: false
    ipRules: [
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

// AI Search creation

resource aiSearch 'Microsoft.Search/searchServices@2025-05-01' = {
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
    publicNetworkAccess: dataPlanePublicNetworkAccess
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

// Some regions doesn't support Standard Zone-Redundant storage, need to use Geo-redundant storage
param noZRSRegions array = ['southindia', 'westus', 'northcentralus']
param sku object = contains(noZRSRegions, location) ? { name: 'Standard_GRS' } : { name: 'Standard_ZRS' }

// Storage creation

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: azureStorageName
  location: location
  kind: 'StorageV2'
  sku: sku
  tags: {}
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: dataPlanePublicNetworkAccess
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
    name: 'inputqueue'
  }

  resource AgentOutputQueue 'queues' = {
    name: 'outputqueue'
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

output aiSearchName string = aiSearch.name
output aiSearchID string = aiSearch.id
output aiSearchServiceResourceGroupName string = resourceGroup().name
output aiSearchServiceSubscriptionId string = subscription().subscriptionId

output azureStorageName string = storage.name
output azureStorageId string = storage.id
output azureStorageResourceGroupName string = resourceGroup().name
output azureStorageSubscriptionId string = subscription().subscriptionId

output cosmosDBName string = cosmosDB.name
output cosmosDBId string = cosmosDB.id
output cosmosDBResourceGroupName string = resourceGroup().name
output cosmosDBSubscriptionId string = subscription().subscriptionId

output storagePrincipalId string = storage.identity.principalId
output aiSearchPrincipalId string = aiSearch.identity.principalId
