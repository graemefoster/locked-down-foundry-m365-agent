/*
Stage 00 — Foundation (orchestrator)

The substrate: zero dependencies. Composes two slices —
  observability.bicep  → Log Analytics + Application Insights (the log sink)
  networking.bicep     → hub + 3 spoke vnets, firewall, DNS resolver, peerings, flow logs

Consumes only main.bicep params/vars; re-exposes the vnet/subnet/log ids every later
stage reads. Networking depends on observability (firewall + flow-log diagnostics).
*/

param location string
param uniqueSuffix string
param vnetName string
param agentSubnetName string
param peSubnetName string
param enableTeamsPublish bool

param logAnalyticsName string
param appInsightsName string
param appServicePlanName string
param firewallPolicyName string
param storageSkuName string

// Deterministic addressing scheme (computed once in main, threaded here + to stage 30).
param agentSubnetCidr string
param appServiceDelegatedSubnetCidr string
param appServicePeSubnetCidr string
param modelGatewayPeSubnetCidr string
param modelGatewayApimSubnetCidr string
param modelGatewaySpokeAddressPrefix string
param firewallUnrestrictedSourceCidrs array

module observability 'observability.bicep' = {
  name: 'stage00-observability-${uniqueSuffix}'
  params: {
    location: location
    logAnalyticsName: logAnalyticsName
    appInsightsName: appInsightsName
  }
}

module networking 'networking.bicep' = {
  name: 'stage00-networking-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    vnetName: vnetName
    agentSubnetName: agentSubnetName
    peSubnetName: peSubnetName
    enableTeamsPublish: enableTeamsPublish
    appServicePlanName: appServicePlanName
    firewallPolicyName: firewallPolicyName
    storageSkuName: storageSkuName
    agentSubnetCidr: agentSubnetCidr
    appServiceDelegatedSubnetCidr: appServiceDelegatedSubnetCidr
    appServicePeSubnetCidr: appServicePeSubnetCidr
    modelGatewayPeSubnetCidr: modelGatewayPeSubnetCidr
    modelGatewayApimSubnetCidr: modelGatewayApimSubnetCidr
    modelGatewaySpokeAddressPrefix: modelGatewaySpokeAddressPrefix
    firewallUnrestrictedSourceCidrs: firewallUnrestrictedSourceCidrs
    logAnalyticsId: observability.outputs.logAnalyticsId
    logAnalyticsCustomerId: observability.outputs.logAnalyticsCustomerId
  }
}

// All privatelink DNS zones are created early here (linked to the hub VNet) and their ids
// are threaded to stage 10 where the private-endpoint zone groups consume them.
module dnsZones 'dns-zones.bicep' = {
  name: 'stage00-dns-zones-${uniqueSuffix}'
  params: {
    suffix: uniqueSuffix
    hubVnetName: networking.outputs.hubVnetName
  }
}

// ==================== OUTPUTS (consumed by stages 10 / 30 / 40) ====================

// Observability
output logAnalyticsId string = observability.outputs.logAnalyticsId
output appInsightsId string = observability.outputs.appInsightsId
output appInsightsConnectionString string = observability.outputs.appInsightsConnectionString

// Hub
output hubVnetName string = networking.outputs.hubVnetName
output hubVnetId string = networking.outputs.hubVnetId

// Foundry spoke
output agentSubnetId string = networking.outputs.agentSubnetId
output foundrySpokeVnetName string = networking.outputs.foundrySpokeVnetName
output foundryPeSubnetName string = networking.outputs.foundryPeSubnetName
output vmSubnetName string = networking.outputs.vmSubnetName

// App Service spoke
output appServiceDelegatedSubnetId string = networking.outputs.appServiceDelegatedSubnetId
output appServiceSpokeVnetName string = networking.outputs.appServiceSpokeVnetName
output appServicePeSubnetName string = networking.outputs.appServicePeSubnetName

// Model-gateway spoke
output modelGatewayApimSubnetId string = networking.outputs.modelGatewayApimSubnetId
output modelGatewayPeSubnetId string = networking.outputs.modelGatewayPeSubnetId

// Private DNS zone ids (created early; consumed by stage 10 private-endpoint zone groups)
output aiServicesDnsZoneId string = dnsZones.outputs.aiServicesDnsZoneId
output openAiDnsZoneId string = dnsZones.outputs.openAiDnsZoneId
output cognitiveServicesDnsZoneId string = dnsZones.outputs.cognitiveServicesDnsZoneId
output aiSearchDnsZoneId string = dnsZones.outputs.aiSearchDnsZoneId
output storageDnsZoneId string = dnsZones.outputs.storageDnsZoneId
output cosmosDBDnsZoneId string = dnsZones.outputs.cosmosDBDnsZoneId
output appServiceDnsZoneId string = dnsZones.outputs.appServiceDnsZoneId
output acrDnsZoneId string = dnsZones.outputs.acrDnsZoneId
output keyVaultDnsZoneId string = dnsZones.outputs.keyVaultDnsZoneId
