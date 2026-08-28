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

// Step 2: Deploy Firewall into Hub VNet (deny-by-default egress-inspection tier)
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

// Firewall private IP — the UDR next hop for all spoke egress.
var firewallPrivateIp = firewall.outputs.firewallPrivateIp

// Step 3: Deploy Foundry Spoke VNet (needs firewall IP + DNS resolver IP)
module foundrySpokeVnet './network/foundry-spoke-vnet.bicep' = {
  name: 'foundry-spoke-${uniqueSuffix}-deployment'
  params: {
    location: location
    vnetName: '${vnetName}-foundry-spoke'
    agentSubnetName: agentSubnetName
    peSubnetName: peSubnetName
    firewallPrivateIp: firewallPrivateIp
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
    // TEMPORARY: East US App Service allocations are unavailable for this subscription.
    location: 'australiaeast'
    vnetName: '${vnetName}-appservice-spoke'
    firewallPrivateIp: firewallPrivateIp
    dnsServerIp: hubNetwork.outputs.dnsResolverInboundIp
  }
}

// Step 4b: Flow logs for the locked-down agent subnet (observability of over-blocking).
// Storage account for raw VNet flow logs — no anonymous blob access, HTTPS only, TLS 1.2.
// The SecurityControl=Ignore tag exempts this account from the MCAPS
// StorageAccount_PublicNetwork_Modify governance policy, which otherwise forces
// publicNetworkAccess=Disabled. The Network Watcher flow-log writer is a Microsoft-managed
// service (NOT in this VNet, so a private endpoint does NOT help it) that reaches the account
// over the trusted-services path — which requires publicNetworkAccess=Enabled with
// defaultAction=Deny + bypass=AzureServices. Without the tag the policy disables public
// access and no flow logs are ever written (0 bytes, empty Traffic Analytics).
//
// Shared-key access is disabled by MCAPS governance, so the flow-log writer CANNOT use the
// account key. Instead the flow log authenticates with the user-assigned managed identity
// below (granted Storage Blob Data Contributor) — see
// https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-managed-identity.
resource flowLogsStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: toLower('${uniqueSuffix}flowlogs')
  location: location
  tags: {
    SecurityControl: 'Ignore'
  }
  sku: {
    name: storageSkuName
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
}

// User-assigned managed identity the VNet flow log uses to write to the (shared-key-disabled)
// storage account and ingest into Traffic Analytics.
resource flowLogsIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${uniqueSuffix}-flowlog-uami'
  location: location
}

// Storage Blob Data Contributor for the flow-log identity on the flow-log storage account.
resource flowLogsBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: flowLogsStorage
  name: guid(flowLogsStorage.id, flowLogsIdentity.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  properties: {
    // Storage Blob Data Contributor
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: flowLogsIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// VNet flow logs live under the regional Network Watcher in NetworkWatcherRG.
// Target the whole VNet (not the agent subnet): the agent subnet is delegated to
// Microsoft.App/environments and delegated subnets produce no flow-log records.
module agentFlowLogs './network/agent-flow-logs.bicep' = {
  name: 'agent-flow-logs-${uniqueSuffix}-deployment'
  scope: resourceGroup('NetworkWatcherRG')
  params: {
    location: location
    targetResourceId: foundrySpokeVnet.outputs.virtualNetworkId
    flowLogsStorageId: flowLogsStorage.id
    flowLogName: '${uniqueSuffix}-agent-vnet-flowlog'
    flowLogsIdentityId: flowLogsIdentity.id
    workspaceResourceId: logAnalyticsId
    workspaceGuid: logAnalyticsCustomerId
    workspaceRegion: location
  }
  dependsOn: [
    flowLogsBlobContributor
  ]
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
module modelGatewaySpokeVnet './network/model-gateway-spoke-vnet.bicep' = {
  name: 'model-gateway-spoke-${uniqueSuffix}-deployment'
  params: {
    location: location
    vnetName: '${vnetName}-model-gateway-spoke'
    vnetAddressPrefix: modelGatewaySpokeAddressPrefix
    firewallPrivateIp: firewallPrivateIp
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

// Cross-spoke traffic is force-tunnelled through the hub firewall (each spoke's 0.0.0.0/0 UDR
// -> firewall private IP), so the hub<->spoke peerings above are sufficient — no direct
// spoke-to-spoke peering is created.

// Hub
output hubVnetName string = hubNetwork.outputs.hubVnetName
output hubVnetId string = hubNetwork.outputs.hubVnetId

// Foundry spoke
output agentSubnetId string = foundrySpokeVnet.outputs.agentSubnetId
output foundrySpokeVnetName string = foundrySpokeVnet.outputs.virtualNetworkName
output foundryPeSubnetName string = foundrySpokeVnet.outputs.peSubnetName
output vmSubnetName string = foundrySpokeVnet.outputs.vmSubnetName
output bastionSubnetId string = foundrySpokeVnet.outputs.bastionSubnetId

// App Service spoke
output appServiceDelegatedSubnetId string = appServiceSpokeVnet.outputs.appServiceDelegatedSubnetId
output appServiceSpokeVnetName string = appServiceSpokeVnet.outputs.virtualNetworkName
output appServicePeSubnetName string = appServiceSpokeVnet.outputs.peSubnetName

// Model-gateway spoke
output modelGatewayApimSubnetId string = modelGatewaySpokeVnet.outputs.apimSubnetId
output modelGatewayPeSubnetId string = modelGatewaySpokeVnet.outputs.peSubnetId
