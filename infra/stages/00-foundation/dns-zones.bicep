/*
Stage 00 slice — Private DNS zones.
All privatelink DNS zones are created early here and linked to the hub VNet for the
DNS resolver; their ids are threaded to stage 10 where the private-endpoint zone
groups consume them. Zone/link names + apiVersions are preserved verbatim.
*/

param suffix string
param hubVnetName string
param hubVnetResourceGroupName string = resourceGroup().name
param hubVnetSubscriptionId string = subscription().subscriptionId

// Reference Hub VNet (DNS zones linked here)
resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: hubVnetName
  scope: resourceGroup(hubVnetSubscriptionId, hubVnetResourceGroupName)
}

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

resource appServiceDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: appServiceDnsZoneName
  location: 'global'
}

resource aiServicesPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: aiServicesDnsZoneName
  location: 'global'
}

resource openAiPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: openAiDnsZoneName
  location: 'global'
}

resource cognitiveServicesPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: cognitiveServicesDnsZoneName
  location: 'global'
}

resource aiSearchPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: aiSearchDnsZoneName
  location: 'global'
}

resource storagePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: storageDnsZoneName
  location: 'global'
}

resource cosmosDBPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: cosmosDBDnsZoneName
  location: 'global'
}

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

// ==================== OUTPUTS (zone ids consumed by stage 10 private-endpoint zone groups) ====================

output aiServicesDnsZoneId string = aiServicesPrivateDnsZone.id
output openAiDnsZoneId string = openAiPrivateDnsZone.id
output cognitiveServicesDnsZoneId string = cognitiveServicesPrivateDnsZone.id
output aiSearchDnsZoneId string = aiSearchPrivateDnsZone.id
output storageDnsZoneId string = storagePrivateDnsZone.id
output cosmosDBDnsZoneId string = cosmosDBPrivateDnsZone.id
output appServiceDnsZoneId string = appServiceDnsZone.id
output acrDnsZoneId string = acrServicePrivateDnsZone.id
output keyVaultDnsZoneId string = keyVaultPrivateDnsZone.id
