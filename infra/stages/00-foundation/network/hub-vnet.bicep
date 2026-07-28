@description('Azure region for the deployment')
param location string

@description('The name of the hub virtual network')
param vnetName string = 'hub-vnet'

@description('Address space for the Hub VNet')
param vnetAddressPrefix string = '10.0.0.0/16'

var firewallSubnet = cidrSubnet(vnetAddressPrefix, 24, 0)
var firewallMgmtSubnet = cidrSubnet(vnetAddressPrefix, 24, 1)
var dnsResolverInboundSubnet = cidrSubnet(vnetAddressPrefix, 28, 32) // 10.0.2.0/28

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: firewallSubnet
        }
      }
      {
        name: 'AzureFirewallManagementSubnet'
        properties: {
          addressPrefix: firewallMgmtSubnet
        }
      }
      {
        name: 'DnsResolverInbound'
        properties: {
          addressPrefix: dnsResolverInboundSubnet
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
output dnsResolverInboundStaticIp string = cidrHost(dnsResolverInboundSubnet, 4)
