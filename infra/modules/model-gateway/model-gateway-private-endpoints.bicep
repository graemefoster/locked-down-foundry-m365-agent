/*
  Model-Gateway: Provider Foundry Private Endpoint + DNS
  ------------------------------------------------------
  Creates the provider Foundry private endpoint that keeps the model provider
  fully private, landing in the gateway spoke's pe-subnet:

    * Provider Foundry PE (groupId 'account') -> services.ai / openai /
      cognitiveservices zones. APIM's outbound VNet-integration subnet reaches
      this PE intra-VNet (no firewall hop).

  The APIM inbound PE + privatelink.azure-api.net zone are handled separately by
  apim-private-endpoint.bicep (always-on), because APIM is now shared by the
  Teams inbound path too.

  DNS:
    * The three Cognitive Services zones ARE already created and hub-linked by
      the core private-endpoint-and-dns.bicep, so this module only REFERENCES
      them (creating them again would collide).
*/

@description('Azure region for the private endpoints')
param location string = resourceGroup().location

@description('Resource ID of the provider Foundry (Cognitive Services) account')
param providerAccountId string

@description('Name of the provider Foundry account (used for PE naming)')
param providerAccountName string

@description('Resource ID of the gateway spoke pe-subnet where the PE lands')
param peSubnetId string

var aiServicesDnsZoneName = 'privatelink.services.ai.azure.com'
var openAiDnsZoneName = 'privatelink.openai.azure.com'
var cognitiveServicesDnsZoneName = 'privatelink.cognitiveservices.azure.com'

/* --------------------- Cognitive Services zones (reference existing by ID) --------------------- */
// These zones are already created + hub-linked by the core private-endpoint-and-dns.bicep in the
// current resource group, so we only need their resource IDs (a privateDnsZoneGroup takes an ID
// string). Computing the ID with resourceId() avoids an 'existing' declaration.
var aiServicesDnsZoneId = resourceId(subscription().subscriptionId, resourceGroup().name, 'Microsoft.Network/privateDnsZones', aiServicesDnsZoneName)
var openAiDnsZoneId = resourceId(subscription().subscriptionId, resourceGroup().name, 'Microsoft.Network/privateDnsZones', openAiDnsZoneName)
var cognitiveServicesDnsZoneId = resourceId(subscription().subscriptionId, resourceGroup().name, 'Microsoft.Network/privateDnsZones', cognitiveServicesDnsZoneName)

/* -------------------------------------- Private Endpoint -------------------------------------- */

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

/* -------------------------------------- DNS Zone Group -------------------------------------- */

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

output providerPrivateEndpointName string = providerPrivateEndpoint.name
