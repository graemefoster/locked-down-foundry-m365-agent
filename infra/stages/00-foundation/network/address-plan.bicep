@description('Hub VNet address space.')
param hubVnetAddressPrefix string

@description('Foundry spoke VNet address space.')
param foundrySpokeAddressPrefix string

@description('App Service spoke VNet address space.')
param appServiceSpokeAddressPrefix string

@description('Model-gateway spoke VNet address space.')
param modelGatewaySpokeAddressPrefix string

output addressPlan object = {
  hub: {
    vnetAddressPrefix: hubVnetAddressPrefix
    firewallSubnetCidr: cidrSubnet(hubVnetAddressPrefix, 24, 0)
    firewallManagementSubnetCidr: cidrSubnet(hubVnetAddressPrefix, 24, 1)
    dnsResolverInboundSubnetCidr: cidrSubnet(hubVnetAddressPrefix, 28, 32)
  }
  foundry: {
    vnetAddressPrefix: foundrySpokeAddressPrefix
    agentSubnetCidr: cidrSubnet(foundrySpokeAddressPrefix, 26, 0)
    peSubnetCidr: cidrSubnet(foundrySpokeAddressPrefix, 26, 1)
    vmSubnetCidr: cidrSubnet(foundrySpokeAddressPrefix, 26, 2)
    deploymentScriptsSubnetCidr: cidrSubnet(foundrySpokeAddressPrefix, 26, 3)
    bastionSubnetCidr: cidrSubnet(foundrySpokeAddressPrefix, 26, 4)
  }
  appService: {
    vnetAddressPrefix: appServiceSpokeAddressPrefix
    delegatedSubnetCidr: cidrSubnet(appServiceSpokeAddressPrefix, 24, 0)
    peSubnetCidr: cidrSubnet(appServiceSpokeAddressPrefix, 24, 1)
  }
  modelGateway: {
    vnetAddressPrefix: modelGatewaySpokeAddressPrefix
    apimSubnetCidr: cidrSubnet(modelGatewaySpokeAddressPrefix, 24, 0)
    peSubnetCidr: cidrSubnet(modelGatewaySpokeAddressPrefix, 24, 1)
  }
}
