@description('Azure region for the deployment')
param location string

@description('The name of the hub virtual network')
param vnetName string = 'hub-vnet'

@description('Hub VNet and subnet CIDRs from the shared address plan.')
param addressPlan object

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPlan.vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: addressPlan.firewallSubnetCidr
        }
      }
      {
        name: 'AzureFirewallManagementSubnet'
        properties: {
          addressPrefix: addressPlan.firewallManagementSubnetCidr
        }
      }
      {
        name: 'DnsResolverInbound'
        properties: {
          addressPrefix: addressPlan.dnsResolverInboundSubnetCidr
          delegations: [
            {
              name: 'Microsoft.Network.dnsResolvers'
              properties: {
                serviceName: 'Microsoft.Network/dnsResolvers'
              }
            }
          ]
        }
      }
    ]
  }
}

output virtualNetworkName string = virtualNetwork.name
output virtualNetworkId string = virtualNetwork.id
output firewallSubnetId string = '${virtualNetwork.id}/subnets/AzureFirewallSubnet'
output firewallManagementSubnetId string = filter(
  virtualNetwork.properties.subnets,
  subnet => subnet.name == 'AzureFirewallManagementSubnet'
)[0].id
output dnsResolverInboundSubnetId string = '${virtualNetwork.id}/subnets/DnsResolverInbound'
output dnsResolverInboundStaticIp string = cidrHost(addressPlan.dnsResolverInboundSubnetCidr, 4)
