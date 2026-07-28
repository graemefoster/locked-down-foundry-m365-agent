/*
Stage 13 module — Foundry account private endpoint & DNS.
The Foundry (AI Services) account gets its private endpoint in the Foundry spoke PE
subnet, with a DNS zone group covering the AI Services / OpenAI / Cognitive Services
privatelink zones. The dependent-resource PEs (Search/Storage/Cosmos/KeyVault/ACR)
live with the data substrate in stage 10; this module carries ONLY the account PE so
the account and everything protecting it read as one unit.
*/

@description('Name of the AI Foundry account')
param aiAccountName string

// Foundry Spoke VNet (for the Foundry account PE)
@description('Name of the Foundry spoke VNet')
param foundrySpokeVnetName string
@description('Name of the PE subnet in Foundry spoke')
param foundryPeSubnetName string

// Private DNS zone ids (created early in stage 00 and threaded in).
param aiServicesDnsZoneId string
param openAiDnsZoneId string
param cognitiveServicesDnsZoneId string

resource aiAccount 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = {
  name: aiAccountName
  scope: resourceGroup()
}

resource foundrySpokeVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: foundrySpokeVnetName
}
resource foundryPeSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: foundrySpokeVnet
  name: foundryPeSubnetName
}

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
}
