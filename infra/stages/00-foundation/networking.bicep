/*
Stage 00 slice — Networking (hub-spoke reachability).
Hub vnet + DNS resolver + firewall, the foundry / app-service / model-gateway spoke
vnets, all hub<->spoke peerings, and the locked-down agent-subnet flow logs.
Takes the Log Analytics id/guid from the observability slice for firewall + flow-log
diagnostics; exposes the vnet/subnet ids every later stage consumes.
*/

param location string
param uniqueSuffix string
param vnetName string
param agentSubnetName string
param peSubnetName string
param appServicePlanName string
param firewallPolicyName string
param storageSkuName string

// Deterministic addressing scheme (from main).
param agentSubnetCidr string
param appServiceDelegatedSubnetCidr string
param appServicePeSubnetCidr string
param modelGatewayPeSubnetCidr string
param modelGatewayApimSubnetCidr string
param modelGatewaySpokeAddressPrefix string
param firewallUnrestrictedSourceCidrs array

// From the observability slice.
param logAnalyticsId string
param logAnalyticsCustomerId string

// Step 1: Deploy Hub VNet + DNS Resolver
module hubNetwork './network/network-agent-vnet.bicep' = {
  name: 'hub-network-${uniqueSuffix}-deployment'
  params: {
    location: location
    vnetName: vnetName
  }
}

// Step 2: Deploy Firewall into Hub VNet
module firewall './network/firewall.bicep' = {
  name: 'stage00-networking-${uniqueSuffix}-fwall'
  params: {
    firewallPipName: '${uniqueSuffix}-fwall-pip'
    firewallMgmtPipName: '${uniqueSuffix}-fwallmgmt-pip'
    firewallName: '${uniqueSuffix}-fwall'
    firewallPolicyName: firewallPolicyName
    firewallSubnetId: hubNetwork.outputs.firewallSubnetId
    firewallManagementSubnetId: hubNetwork.outputs.firewallManagementSubnetId
    location: location
    logAnalyticsId: logAnalyticsId
    yarpProxyFqdn: 'yarp-${appServicePlanName}.azurewebsites.net'
    agentSubnetCidr: agentSubnetCidr
    appServicePeSubnetCidr: appServicePeSubnetCidr
    unrestrictedSourceCidrs: firewallUnrestrictedSourceCidrs
  }
}

// Step 3: Deploy Foundry Spoke VNet (needs firewall IP + DNS resolver IP)
module foundrySpokeVnet './network/foundry-spoke-vnet.bicep' = {
  name: 'foundry-spoke-${uniqueSuffix}-deployment'
  params: {
    location: location
    vnetName: '${vnetName}-foundry-spoke'
    agentSubnetName: agentSubnetName
    peSubnetName: peSubnetName
    firewallPrivateIp: firewall.outputs.firewallPrivateIp
    dnsServerIp: hubNetwork.outputs.dnsResolverInboundIp
    agentInboundAllowedCidrs: [
      appServiceDelegatedSubnetCidr
    ]
    modelGatewayPeCidr: modelGatewayPeSubnetCidr
    appServicePeCidr: appServicePeSubnetCidr
    apimSubnetCidr: modelGatewayApimSubnetCidr
  }
}

// Step 4: Deploy App Service Spoke VNet (needs firewall IP + DNS resolver IP)
module appServiceSpokeVnet './network/appservice-spoke-vnet.bicep' = {
  name: 'appservice-spoke-${uniqueSuffix}-deployment'
  params: {
    location: location
    vnetName: '${vnetName}-appservice-spoke'
    firewallPrivateIp: firewall.outputs.firewallPrivateIp
    dnsServerIp: hubNetwork.outputs.dnsResolverInboundIp
  }
}

// Step 4b: Flow logs for the locked-down agent subnet (observability of over-blocking).
// Storage account for raw VNet flow logs — no anonymous blob access, HTTPS only, TLS 1.2.
resource flowLogsStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: toLower('${uniqueSuffix}flowlogs')
  location: location
  sku: {
    name: storageSkuName
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

// VNet flow logs live under the regional Network Watcher in NetworkWatcherRG.
module agentFlowLogs './network/agent-flow-logs.bicep' = {
  name: 'agent-flow-logs-${uniqueSuffix}-deployment'
  scope: resourceGroup('NetworkWatcherRG')
  params: {
    location: location
    targetSubnetId: foundrySpokeVnet.outputs.agentSubnetId
    flowLogsStorageId: flowLogsStorage.id
    flowLogName: '${uniqueSuffix}-agent-subnet-flowlog'
    workspaceResourceId: logAnalyticsId
    workspaceGuid: logAnalyticsCustomerId
    workspaceRegion: location
  }
}

// Step 5: VNet Peerings (Hub ↔ Foundry Spoke)
module hubToFoundryPeering './network/vnet-peering.bicep' = {
  name: 'hub-foundry-peering-${uniqueSuffix}'
  params: {
    hubVnetName: hubNetwork.outputs.hubVnetName
    spokeVnetName: foundrySpokeVnet.outputs.virtualNetworkName
    hubVnetId: hubNetwork.outputs.hubVnetId
    spokeVnetId: foundrySpokeVnet.outputs.virtualNetworkId
  }
}

// Step 6: VNet Peerings (Hub ↔ App Service Spoke)
module hubToAppServicePeering './network/vnet-peering.bicep' = {
  name: 'hub-appservice-peering-${uniqueSuffix}'
  params: {
    hubVnetName: hubNetwork.outputs.hubVnetName
    spokeVnetName: appServiceSpokeVnet.outputs.virtualNetworkName
    hubVnetId: hubNetwork.outputs.hubVnetId
    spokeVnetId: appServiceSpokeVnet.outputs.virtualNetworkId
  }
}

// Step 7: model-gateway spoke VNet (always deployed; pure network — moved up from its
// former late position). APIM (which lives in this spoke) is shared by the model gateway
// AND the Teams/M365 publish inbound path.
module modelGatewaySpokeVnet './model-gateway/model-gateway-spoke-vnet.bicep' = {
  name: 'model-gateway-spoke-${uniqueSuffix}-deployment'
  params: {
    location: location
    vnetName: '${vnetName}-model-gateway-spoke'
    vnetAddressPrefix: modelGatewaySpokeAddressPrefix
    firewallPrivateIp: firewall.outputs.firewallPrivateIp
    dnsServerIp: hubNetwork.outputs.dnsResolverInboundIp
  }
}

// Step 8: peer hub <-> model-gateway spoke (always, alongside the spoke VNet)
module hubToModelGatewayPeering './network/vnet-peering.bicep' = {
  name: 'hub-model-gateway-peering-${uniqueSuffix}'
  params: {
    hubVnetName: hubNetwork.outputs.hubVnetName
    spokeVnetName: modelGatewaySpokeVnet.outputs.virtualNetworkName
    hubVnetId: hubNetwork.outputs.hubVnetId
    spokeVnetId: modelGatewaySpokeVnet.outputs.virtualNetworkId
  }
}

// Hub
output hubVnetName string = hubNetwork.outputs.hubVnetName
output hubVnetId string = hubNetwork.outputs.hubVnetId

// Foundry spoke
output agentSubnetId string = foundrySpokeVnet.outputs.agentSubnetId
output foundrySpokeVnetName string = foundrySpokeVnet.outputs.virtualNetworkName
output foundryPeSubnetName string = foundrySpokeVnet.outputs.peSubnetName
output vmSubnetName string = foundrySpokeVnet.outputs.vmSubnetName

// App Service spoke
output appServiceDelegatedSubnetId string = appServiceSpokeVnet.outputs.appServiceDelegatedSubnetId
output appServiceSpokeVnetName string = appServiceSpokeVnet.outputs.virtualNetworkName
output appServicePeSubnetName string = appServiceSpokeVnet.outputs.peSubnetName

// Model-gateway spoke
output modelGatewayApimSubnetId string = modelGatewaySpokeVnet.outputs.apimSubnetId
output modelGatewayPeSubnetId string = modelGatewaySpokeVnet.outputs.peSubnetId
