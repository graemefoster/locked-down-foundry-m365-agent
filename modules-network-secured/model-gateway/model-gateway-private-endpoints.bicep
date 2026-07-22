/*
  Model-Gateway: Private Endpoints + DNS
  --------------------------------------
  Creates the two private endpoints that keep the gateway spoke fully private,
  both landing in the gateway spoke's pe-subnet:

    * APIM inbound PE (groupId 'Gateway')  -> privatelink.azure-api.net
      The primary Foundry project reaches the gateway ONLY through this PE
      (APIM publicNetworkAccess is Disabled). The agent force-tunnels to it via
      the Azure Firewall.
    * Provider Foundry PE (groupId 'account') -> services.ai / openai /
      cognitiveservices zones. APIM's outbound VNet-integration subnet reaches
      this PE intra-VNet (no firewall hop).

  DNS:
    * privatelink.azure-api.net is NOT created anywhere else, so this module
      creates it (or references an existing one) and links it to the HUB VNet,
      where the DNS Private Resolver lives — that is what makes the A-record
      resolvable from every spoke.
    * The three Cognitive Services zones ARE already created and hub-linked by
      the core private-endpoint-and-dns.bicep, so this module only REFERENCES
      them (creating them again would collide).

  Modelled on modules-network-secured/private-endpoint-and-dns.bicep.
*/

@description('Azure region for the private endpoints')
param location string = resourceGroup().location

@description('Suffix for unique resource / link names')
param suffix string

@description('Resource ID of the APIM instance')
param apimId string

@description('Name of the APIM instance (used for PE naming)')
param apimName string

@description('Resource ID of the provider Foundry (Cognitive Services) account')
param providerAccountId string

@description('Name of the provider Foundry account (used for PE naming)')
param providerAccountName string

@description('Resource ID of the gateway spoke pe-subnet where both PEs land')
param peSubnetId string

@description('Resource ID of the Hub VNet (privatelink.azure-api.net is linked here for the resolver)')
param hubVnetId string

var apimDnsZoneName = 'privatelink.azure-api.net'
var aiServicesDnsZoneName = 'privatelink.services.ai.azure.com'
var openAiDnsZoneName = 'privatelink.openai.azure.com'
var cognitiveServicesDnsZoneName = 'privatelink.cognitiveservices.azure.com'

/* ----------------------------- APIM DNS zone ----------------------------- */

resource apimDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: apimDnsZoneName
  location: 'global'
}

var apimDnsZoneId = apimDnsZone.id

// Link the APIM zone to the Hub VNet (DNS resolver lives there) so every spoke resolves it.
resource apimDnsZoneHubLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: apimDnsZone
  location: 'global'
  name: 'apim-${suffix}-hub-link'
  properties: {
    virtualNetwork: { id: hubVnetId }
    registrationEnabled: false
  }
}

/* --------------------- Cognitive Services zones (reference existing by ID) --------------------- */
// These zones are already created + hub-linked by the core private-endpoint-and-dns.bicep in the
// current resource group, so we only need their resource IDs (a privateDnsZoneGroup takes an ID
// string). Computing the ID with resourceId() avoids an 'existing' declaration.
var aiServicesDnsZoneId = resourceId(subscription().subscriptionId, resourceGroup().name, 'Microsoft.Network/privateDnsZones', aiServicesDnsZoneName)
var openAiDnsZoneId = resourceId(subscription().subscriptionId, resourceGroup().name, 'Microsoft.Network/privateDnsZones', openAiDnsZoneName)
var cognitiveServicesDnsZoneId = resourceId(subscription().subscriptionId, resourceGroup().name, 'Microsoft.Network/privateDnsZones', cognitiveServicesDnsZoneName)

/* -------------------------------------- Private Endpoints -------------------------------------- */

resource apimPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${apimName}-private-endpoint'
  location: location
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${apimName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: apimId
          groupIds: ['Gateway']
        }
      }
    ]
  }
}

resource providerPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${providerAccountName}-private-endpoint'
  location: location
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${providerAccountName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: providerAccountId
          groupIds: ['account']
        }
      }
    ]
  }
}

/* -------------------------------------- DNS Zone Groups -------------------------------------- */

resource apimDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: apimPrivateEndpoint
  name: '${apimName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${apimName}-dns-config', properties: { privateDnsZoneId: apimDnsZoneId } }
    ]
  }
  dependsOn: [
    apimDnsZoneHubLink
  ]
}

resource providerDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: providerPrivateEndpoint
  name: '${providerAccountName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${providerAccountName}-dns-aiserv-config', properties: { privateDnsZoneId: aiServicesDnsZoneId } }
      { name: '${providerAccountName}-dns-openai-config', properties: { privateDnsZoneId: openAiDnsZoneId } }
      { name: '${providerAccountName}-dns-cogserv-config', properties: { privateDnsZoneId: cognitiveServicesDnsZoneId } }
    ]
  }
}

output apimPrivateEndpointName string = apimPrivateEndpoint.name
output providerPrivateEndpointName string = providerPrivateEndpoint.name
output apimDnsZoneId string = apimDnsZoneId
