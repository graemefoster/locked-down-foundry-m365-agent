/*
Private Endpoint and DNS Configuration Module (Hub-Spoke) — data resources.
------------------------------------------
Hub-spoke architecture:
- Private DNS zones linked to the Hub VNet (for DNS Resolver)
- Data-resource PEs (Search, Storage, Cosmos, ACR, Key Vault) in Foundry Spoke PE subnet
- DNS zones also linked to respective spoke VNets for local resolution

The Foundry (AI Services) account PE lives with the account in stage 13
(network/ai-account-private-endpoint.bicep), not here.
*/

// Resource names and identifiers
@description('Name of the AI Search service')
param aiSearchName string
@description('Name of the storage account')
param storageName string
@description('Name of the Cosmos DB account')
param cosmosDBName string

// Foundry Spoke VNet (for Foundry PEs)
@description('Name of the Foundry spoke VNet')
param foundrySpokeVnetName string
@description('Name of the PE subnet in Foundry spoke')
param foundryPeSubnetName string

param acrName string
param keyVaultName string

// Private DNS zone ids (created early in stage 00 and threaded in).
param aiSearchDnsZoneId string
param storageDnsZoneId string
param cosmosDBDnsZoneId string
param acrDnsZoneId string
param keyVaultDnsZoneId string

// ---- Resource references ----
resource aiSearch 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: aiSearchName
  scope: resourceGroup()
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName
  scope: resourceGroup()
}

resource cosmosDBAccount 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosDBName
  scope: resourceGroup()
}

resource acr 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: acrName
  scope: resourceGroup()
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
  scope: resourceGroup()
}

// Reference Foundry Spoke VNet and PE subnet
resource foundrySpokeVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: foundrySpokeVnetName
}
resource foundryPeSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: foundrySpokeVnet
  name: foundryPeSubnetName
}

/* -------------------------------------------- Data-resource PEs (in Foundry Spoke) -------------------------------------------- */

resource aiSearchPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${aiSearchName}-private-endpoint'
  location: resourceGroup().location
  properties: {
    subnet: { id: foundryPeSubnet.id }
    privateLinkServiceConnections: [
      {
        name: '${aiSearchName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: aiSearch.id
          groupIds: ['searchService']
        }
      }
    ]
  }
}

resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${storageName}-private-endpoint'
  location: resourceGroup().location
  properties: {
    subnet: { id: foundryPeSubnet.id }
    privateLinkServiceConnections: [
      {
        name: '${storageName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['blob']
        }
      }
    ]
  }
}

resource cosmosDBPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${cosmosDBName}-private-endpoint'
  location: resourceGroup().location
  properties: {
    subnet: { id: foundryPeSubnet.id }
    privateLinkServiceConnections: [
      {
        name: '${cosmosDBName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: cosmosDBAccount.id
          groupIds: ['Sql']
        }
      }
    ]
  }
}

resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${keyVaultName}-private-endpoint'
  location: resourceGroup().location
  properties: {
    subnet: { id: foundryPeSubnet.id }
    privateLinkServiceConnections: [
      {
        name: '${keyVaultName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}

resource acrPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${acrName}-private-endpoint'
  location: resourceGroup().location
  properties: {
    subnet: { id: foundryPeSubnet.id }
    privateLinkServiceConnections: [
      {
        name: '${acrName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: acr.id
          groupIds: ['registry']
        }
      }
    ]
  }
}

/* -------------------------------------------- App Service PEs (in App Service Spoke) -------------------------------------------- */

// ---- DNS Zone Groups ----
resource aiSearchDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: aiSearchPrivateEndpoint
  name: '${aiSearchName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${aiSearchName}-dns-config', properties: { privateDnsZoneId: aiSearchDnsZoneId } }
    ]
  }
}
resource storageDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: storagePrivateEndpoint
  name: '${storageName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${storageName}-dns-config', properties: { privateDnsZoneId: storageDnsZoneId } }
    ]
  }
}
resource cosmosDBDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: cosmosDBPrivateEndpoint
  name: '${cosmosDBName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${cosmosDBName}-dns-config', properties: { privateDnsZoneId: cosmosDBDnsZoneId } }
    ]
  }
}

resource keyVaultDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: keyVaultPrivateEndpoint
  name: '${keyVaultName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${keyVaultName}-dns-config', properties: { privateDnsZoneId: keyVaultDnsZoneId } }
    ]
  }
}

resource acrDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: acrPrivateEndpoint
  name: '${acrName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${acrName}-dns-config', properties: { privateDnsZoneId: acrDnsZoneId } }
    ]
  }
}
