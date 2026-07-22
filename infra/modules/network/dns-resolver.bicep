@description('Azure region for the deployment')
param location string

@description('Name of the DNS Resolver')
param dnsResolverName string

@description('Resource ID of the Hub VNet')
param hubVnetId string

@description('Resource ID of the inbound endpoint subnet')
param inboundSubnetId string

@description('Static IP address for the inbound endpoint (must be within the inbound subnet range)')
param inboundStaticIp string

resource dnsResolver 'Microsoft.Network/dnsResolvers@2022-07-01' = {
  name: dnsResolverName
  location: location
  properties: {
    virtualNetwork: {
      id: hubVnetId
    }
  }
}

resource inboundEndpoint 'Microsoft.Network/dnsResolvers/inboundEndpoints@2022-07-01' = {
  parent: dnsResolver
  name: '${dnsResolverName}-inbound'
  location: location
  properties: {
    ipConfigurations: [
      {
        subnet: {
          id: inboundSubnetId
        }
        privateIpAddress: inboundStaticIp
        privateIpAllocationMethod: 'Static'
      }
    ]
  }
}

output dnsResolverInboundIp string = inboundEndpoint.properties.ipConfigurations[0].privateIpAddress
