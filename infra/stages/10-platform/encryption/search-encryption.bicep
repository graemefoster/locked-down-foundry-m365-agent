// Updates the AI Search service with a service-level customer-managed key after RBAC is
// assigned. The base service (standard-dependent-resources.bicep) sets
// encryptionWithCmk.enforcement = 'Enabled' but cannot set the key at creation time because the
// Key Vault Crypto Service Encryption User role granted to the search identity must be effective
// first (same chicken-and-egg as the Storage CMK re-PUT). Without a service-level key, CMK
// enforcement makes every new index/indexer/skillset/etc. fail unless it carries an object-level
// key, so we configure the service-level default here.
//
// serviceLevelEncryptionKey requires Search Management API 2026-03-01-preview or later.

@description('Name of the AI Search service')
param aiSearchName string

@description('Location for the resource')
param location string

@description('Key Vault URI (e.g. https://<vault>.vault.azure.net)')
param keyVaultUri string

@description('Key name in the Key Vault')
param keyVaultKeyName string

@description('Key version in the Key Vault')
param keyVaultKeyVersion string

// Private-endpoint-only data plane: public network access is always disabled (matches the base
// service definition so this full PUT does not reset it).
var dataPlanePublicNetworkAccess = 'Disabled'

resource existingSearch 'Microsoft.Search/searchServices@2026-03-01-preview' existing = {
  name: aiSearchName
}

#disable-next-line BCP036
resource searchUpdate 'Microsoft.Search/searchServices@2026-03-01-preview' = {
  name: existingSearch.name
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    disableLocalAuth: false
    authOptions: { aadOrApiKey: { aadAuthFailureMode: 'http401WithBearerChallenge' } }
    encryptionWithCmk: {
      enforcement: 'Enabled'
      serviceLevelEncryptionKey: {
        keyVaultUri: keyVaultUri
        keyVaultKeyName: keyVaultKeyName
        keyVaultKeyVersion: keyVaultKeyVersion
      }
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
