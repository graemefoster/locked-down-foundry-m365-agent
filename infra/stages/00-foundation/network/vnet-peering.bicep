@description('Name of the hub virtual network')
param hubVnetName string

@description('Name of the spoke virtual network')
param spokeVnetName string

@description('Resource ID of the spoke virtual network')
param spokeVnetId string

@description('Resource ID of the hub virtual network')
param hubVnetId string

// Generic bidirectional VNet peering between two VNets. Named with hub/spoke params for its
// original hub<->spoke use, but also reused for spoke<->spoke peerings (firewall opt-out tier),
// where "hub" is simply the first VNet and "spoke" the second — the peering is symmetric.
// Hub to Spoke peering
resource hubToSpokePeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  name: '${hubVnetName}/peer-to-${spokeVnetName}'
  properties: {
    remoteVirtualNetwork: {
      id: spokeVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// Spoke to Hub peering
resource spokeToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  name: '${spokeVnetName}/peer-to-${hubVnetName}'
  properties: {
    remoteVirtualNetwork: {
      id: hubVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}
