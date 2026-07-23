/*
  APIM inbound Private Endpoint + DNS  (always-on)
  ------------------------------------------------
  APIM is now shared by two scenarios (the optional model gateway AND the
  optional Teams/M365 publish inbound path), so its inbound private endpoint and
  the privatelink.azure-api.net DNS zone are ALWAYS deployed. Callers reach the
  gateway ONLY through this PE (APIM
  publicNetworkAccess is flipped to 'Disabled' by apim-lockdown.bicep):

    * the primary Foundry project (model-gateway connection), and
    * the YARP proxy (Teams inbound path),

  both force-tunnel to this PE via the Azure Firewall (no spoke-to-spoke peering).

  DNS:
    * privatelink.azure-api.net is NOT created anywhere else, so this module
      creates it and links it to the HUB VNet, where the DNS Private Resolver
      lives — that is what makes the A-record resolvable from every spoke.

  Extracted from model-gateway-private-endpoints.bicep so it can deploy without
  the (gated) provider Foundry.
*/

@description('Azure region for the private endpoint')
param location string = resourceGroup().location

@description('Suffix for unique resource / link names')
param suffix string

@description('Resource ID of the APIM instance')
param apimId string

@description('Name of the APIM instance (used for PE naming)')
param apimName string

@description('Resource ID of the gateway spoke pe-subnet where the PE lands')
param peSubnetId string

@description('Resource ID of the Hub VNet (privatelink.azure-api.net is linked here for the resolver)')
param hubVnetId string

var apimDnsZoneName = 'privatelink.azure-api.net'

resource apimDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: apimDnsZoneName
  location: 'global'
}

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

resource apimDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: apimPrivateEndpoint
  name: '${apimName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${apimName}-dns-config', properties: { privateDnsZoneId: apimDnsZone.id } }
    ]
  }
  dependsOn: [
    apimDnsZoneHubLink
  ]
}

output apimPrivateEndpointName string = apimPrivateEndpoint.name
output apimDnsZoneId string = apimDnsZone.id
