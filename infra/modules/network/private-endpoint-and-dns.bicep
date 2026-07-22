/*
Private Endpoint and DNS Configuration Module (Hub-Spoke)
------------------------------------------
Hub-spoke architecture:
- Private DNS zones linked to the Hub VNet (for DNS Resolver)
- Foundry service PEs (AI, Search, Storage, Cosmos) in Foundry Spoke PE subnet
- App Service PEs in App Service Spoke PE subnet
- DNS zones also linked to respective spoke VNets for local resolution
*/

// Resource names and identifiers
@description('Name of the AI Foundry account')
param aiAccountName string
@description('Name of the AI Search service')
param aiSearchName string
@description('Name of the storage account')
param storageName string
@description('Name of the Cosmos DB account')
param cosmosDBName string
@description('Suffix for unique resource names')
param suffix string

// Hub VNet (for DNS zone links - resolver lives here)
@description('Name of the Hub VNet')
param hubVnetName string
@description('Resource Group of the Hub VNet')
param hubVnetResourceGroupName string = resourceGroup().name
@description('Subscription ID of the Hub VNet')
param hubVnetSubscriptionId string = subscription().subscriptionId

// Foundry Spoke VNet (for Foundry PEs)
@description('Name of the Foundry spoke VNet')
param foundrySpokeVnetName string
@description('Name of the PE subnet in Foundry spoke')
param foundryPeSubnetName string

// App Service Spoke VNet (for App Service PEs)
@description('Name of the App Service spoke VNet')
param appServiceSpokeVnetName string
@description('Name of the PE subnet in App Service spoke')
param appServicePeSubnetName string

param appServiceWebAppNames string[]
param acrName string
param keyVaultName string

// ---- Resource references ----
resource aiAccount 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = {
  name: aiAccountName
  scope: resourceGroup()
}

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

// Reference Hub VNet (DNS zones linked here)
resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: hubVnetName
  scope: resourceGroup(hubVnetSubscriptionId, hubVnetResourceGroupName)
}

// Reference Foundry Spoke VNet and PE subnet
resource foundrySpokeVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: foundrySpokeVnetName
}
resource foundryPeSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: foundrySpokeVnet
  name: foundryPeSubnetName
}

// Reference App Service Spoke VNet and PE subnet
resource appServiceSpokeVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: appServiceSpokeVnetName
}
resource appServicePeSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: appServiceSpokeVnet
  name: appServicePeSubnetName
}

/* -------------------------------------------- Foundry PEs (in Foundry Spoke) -------------------------------------------- */

resource aiAccountPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${aiAccountName}-private-endpoint'
  location: resourceGroup().location
  properties: {
    subnet: { id: foundryPeSubnet.id }
    privateLinkServiceConnections: [
      {
        name: '${aiAccountName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: aiAccount.id
          groupIds: ['account']
        }
      }
    ]
  }
}

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

resource appService 'Microsoft.Web/sites@2025-03-01' existing = [
  for appServiceWebAppName in appServiceWebAppNames: {
    name: appServiceWebAppName
  }
]

resource appServicePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = [
  for (appServiceWebAppName, i) in appServiceWebAppNames: {
    name: '${appServiceWebAppName}-private-endpoint'
    location: resourceGroup().location
    properties: {
      subnet: { id: appServicePeSubnet.id }
      privateLinkServiceConnections: [
        {
          name: '${appServiceWebAppName}-private-link-service-connection'
          properties: {
            privateLinkServiceId: appService[i].id
            groupIds: ['sites']
          }
        }
      ]
    }
  }
]

/* -------------------------------------------- Private DNS Zones -------------------------------------------- */

var aiServicesDnsZoneName = 'privatelink.services.ai.azure.com'
var openAiDnsZoneName = 'privatelink.openai.azure.com'
var cognitiveServicesDnsZoneName = 'privatelink.cognitiveservices.azure.com'
var aiSearchDnsZoneName = 'privatelink.search.windows.net'
var storageDnsZoneName = 'privatelink.blob.${environment().suffixes.storage}'
var cosmosDBDnsZoneName = 'privatelink.documents.azure.com'
var appServiceDnsZoneName = 'privatelink.azurewebsites.net'
var acrDnsZoneName = 'privatelink.azurecr.io'
var keyVaultDnsZoneName = 'privatelink.vaultcore.azure.net'

// ---- DNS Zone Resources ----
resource acrServicePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: acrDnsZoneName
  location: 'global'
}

resource keyVaultPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: keyVaultDnsZoneName
  location: 'global'
}
var keyVaultDnsZoneId = keyVaultPrivateDnsZone.id

resource appServiceDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: appServiceDnsZoneName
  location: 'global'
}

resource aiServicesPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: aiServicesDnsZoneName
  location: 'global'
}
var aiServicesDnsZoneId = aiServicesPrivateDnsZone.id

resource openAiPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: openAiDnsZoneName
  location: 'global'
}
var openAiDnsZoneId = openAiPrivateDnsZone.id

resource cognitiveServicesPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: cognitiveServicesDnsZoneName
  location: 'global'
}
var cognitiveServicesDnsZoneId = cognitiveServicesPrivateDnsZone.id

resource aiSearchPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: aiSearchDnsZoneName
  location: 'global'
}
var aiSearchDnsZoneId = aiSearchPrivateDnsZone.id

resource storagePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: storageDnsZoneName
  location: 'global'
}
var storageDnsZoneId = storagePrivateDnsZone.id

resource cosmosDBPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: cosmosDBDnsZoneName
  location: 'global'
}
var cosmosDBDnsZoneId = cosmosDBPrivateDnsZone.id

/* ---- DNS VNet Links (all zones linked to Hub VNet for DNS Resolver) ---- */

resource acrLinkHub 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: acrServicePrivateDnsZone
  location: 'global'
  name: 'acr-${suffix}-hub-link'
  properties: {
    virtualNetwork: { id: hubVnet.id }
    registrationEnabled: false
  }
}

resource keyVaultLinkHub 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: keyVaultPrivateDnsZone
  location: 'global'
  name: 'keyvault-${suffix}-hub-link'
  properties: {
    virtualNetwork: { id: hubVnet.id }
    registrationEnabled: false
  }
}

resource aiServicesLinkHub 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: aiServicesPrivateDnsZone
  location: 'global'
  name: 'aiServices-${suffix}-hub-link'
  properties: {
    virtualNetwork: { id: hubVnet.id }
    registrationEnabled: false
  }
}
resource openAiLinkHub 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: openAiPrivateDnsZone
  location: 'global'
  name: 'aiServicesOpenAI-${suffix}-hub-link'
  properties: {
    virtualNetwork: { id: hubVnet.id }
    registrationEnabled: false
  }
}
resource cognitiveServicesLinkHub 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: cognitiveServicesPrivateDnsZone
  location: 'global'
  name: 'aiServicesCognitiveServices-${suffix}-hub-link'
  properties: {
    virtualNetwork: { id: hubVnet.id }
    registrationEnabled: false
  }
}
resource aiSearchLinkHub 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: aiSearchPrivateDnsZone
  location: 'global'
  name: 'aiSearch-${suffix}-hub-link'
  properties: {
    virtualNetwork: { id: hubVnet.id }
    registrationEnabled: false
  }
}
resource storageLinkHub 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: storagePrivateDnsZone
  location: 'global'
  name: 'storage-${suffix}-hub-link'
  properties: {
    virtualNetwork: { id: hubVnet.id }
    registrationEnabled: false
  }
}
resource cosmosDBLinkHub 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: cosmosDBPrivateDnsZone
  location: 'global'
  name: 'cosmosDB-${suffix}-hub-link'
  properties: {
    virtualNetwork: { id: hubVnet.id }
    registrationEnabled: false
  }
}

// App Service DNS zone linked to Hub (for resolver) and App Service spoke (for local resolution)
resource appServiceLinkHub 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: appServiceDnsZone
  location: 'global'
  name: 'appservice-${suffix}-hub-link'
  properties: {
    virtualNetwork: { id: hubVnet.id }
    registrationEnabled: false
  }
}

// ---- DNS Zone Groups ----
resource aiServicesDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: aiAccountPrivateEndpoint
  name: '${aiAccountName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${aiAccountName}-dns-aiserv-config', properties: { privateDnsZoneId: aiServicesDnsZoneId } }
      { name: '${aiAccountName}-dns-openai-config', properties: { privateDnsZoneId: openAiDnsZoneId } }
      { name: '${aiAccountName}-dns-cogserv-config', properties: { privateDnsZoneId: cognitiveServicesDnsZoneId } }
    ]
  }
  dependsOn: [
    aiServicesLinkHub
    openAiLinkHub
    cognitiveServicesLinkHub
  ]
}
resource aiSearchDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: aiSearchPrivateEndpoint
  name: '${aiSearchName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${aiSearchName}-dns-config', properties: { privateDnsZoneId: aiSearchDnsZoneId } }
    ]
  }
  dependsOn: [
    aiSearchLinkHub
  ]
}
resource storageDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: storagePrivateEndpoint
  name: '${storageName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${storageName}-dns-config', properties: { privateDnsZoneId: storageDnsZoneId } }
    ]
  }
  dependsOn: [
    storageLinkHub
  ]
}
resource cosmosDBDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: cosmosDBPrivateEndpoint
  name: '${cosmosDBName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${cosmosDBName}-dns-config', properties: { privateDnsZoneId: cosmosDBDnsZoneId } }
    ]
  }
  dependsOn: [
    cosmosDBLinkHub
  ]
}

resource keyVaultDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: keyVaultPrivateEndpoint
  name: '${keyVaultName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${keyVaultName}-dns-config', properties: { privateDnsZoneId: keyVaultDnsZoneId } }
    ]
  }
  dependsOn: [
    keyVaultLinkHub
  ]
}

resource appServiceDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [
  for (appServiceName, i) in appServiceWebAppNames: {
    name: '${appServiceName}-dns-group'
    parent: appServicePrivateEndpoint[i]
    properties: {
      privateDnsZoneConfigs: [
        { name: '${appServiceName}-dns-config', properties: { privateDnsZoneId: appServiceDnsZone.id } }
      ]
    }
    dependsOn: [
      appServiceLinkHub
    ]
  }
]

resource acrDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: acrPrivateEndpoint
  name: '${acrName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${acrName}-dns-config', properties: { privateDnsZoneId: acrServicePrivateDnsZone.id } }
    ]
  }
  dependsOn: [
    acrLinkHub
  ]
}
