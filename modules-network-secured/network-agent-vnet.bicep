/*
  Hub-Spoke Network Orchestrator - Hub VNet Only
  Deploys the Hub VNet with firewall and DNS resolver subnets.
  Spoke VNets are deployed separately (they need the firewall private IP
  which is only available after the firewall deploys into the hub).
*/

@description('Azure region for the deployment')
param location string

@description('Base name prefix for the virtual networks')
param vnetName string

// Hub address space
var hubAddressPrefix = '10.0.0.0/16'

// Deploy Hub VNet (firewall + DNS resolver subnets)
module hubVnet 'hub-vnet.bicep' = {
  name: 'hub-vnet-deployment'
  params: {
    location: location
    vnetName: '${vnetName}-hub'
    vnetAddressPrefix: hubAddressPrefix
  }
}

// Deploy DNS Resolver in Hub
module dnsResolver 'dns-resolver.bicep' = {
  name: 'dns-resolver-deployment'
  params: {
    location: location
    dnsResolverName: '${vnetName}-dns-resolver'
    hubVnetId: hubVnet.outputs.virtualNetworkId
    inboundSubnetId: hubVnet.outputs.dnsResolverInboundSubnetId
    inboundStaticIp: hubVnet.outputs.dnsResolverInboundStaticIp
  }
}

// Hub outputs
output hubVnetName string = hubVnet.outputs.virtualNetworkName
output hubVnetId string = hubVnet.outputs.virtualNetworkId
output firewallSubnetId string = hubVnet.outputs.firewallSubnetId
output firewallManagementSubnetId string = hubVnet.outputs.firewallManagementSubnetId
output dnsResolverInboundIp string = dnsResolver.outputs.dnsResolverInboundIp
