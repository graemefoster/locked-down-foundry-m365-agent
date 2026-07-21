/*
Standard Setup Network Secured Steps for main.bicep - Hub-Spoke Architecture
-----------------------------------
Hub VNet: Firewall + DNS Resolver
App Service Spoke: YARP proxy + MCP web apps
Foundry Spoke: AI Services, Storage, CosmosDB, AI Search, VM/Bastion
*/
@description('Location for all resources.')
@allowed([
  'westus'
  'eastus'
  'eastus2'
  'japaneast'
  'francecentral'
  'spaincentral'
  'uaenorth'
  'southcentralus'
  'italynorth'
  'germanywestcentral'
  'brazilsouth'
  'southafricanorth'
  'australiaeast'
  'swedencentral'
  'canadaeast'
  'westeurope'
  'westus3'
  'uksouth'
  'southindia'

  //only class B and C
  'koreacentral'
  'polandcentral'
  'switzerlandnorth'
  'norwayeast'

  //hosted agents:
  'northcentralus'
])
param location string = 'eastus'

@description('Name for your AI Services resource.')
param aiServices string = 'aiservices'

// Model deployment parameters
@description('The name of the model you want to deploy')
param modelName string = 'gpt-4o'
@description('The provider of your model')
param modelFormat string = 'OpenAI'
@description('The version of your model')
param modelVersion string = '2024-11-20'
@description('The sku of your model deployment')
param modelSkuName string = 'GlobalStandard'
@description('The tokens per minute (TPM) of your model deployment')
param modelCapacity int = 30

// ==================== MODEL GATEWAY (optional) ====================
@description('Deploy the optional enterprise model gateway: an APIM Standard v2 instance + a "real" provider AI Foundry in a NEW spoke, advertised to the primary Foundry project as an ApiManagement connection. Default false to avoid cost.')
param enableModelGateway bool = false

@description('Model exposed through the gateway (deployed on the provider Foundry and advertised on the connection).')
param gatewayModelName string = 'gpt-5.4-mini'

@description('Format of the gateway-exposed model.')
param gatewayModelFormat string = 'OpenAI'

@description('Version of the gateway-exposed model. Set to a valid version for gatewayModelName.')
param gatewayModelVersion string = '2026-03-05'

@description('SKU of the gateway-exposed model deployment.')
param gatewayModelSkuName string = 'GlobalStandard'

@description('Capacity (TPM) of the gateway-exposed model deployment.')
param gatewayModelCapacity int = 30

@description('Optional caller app/client ID to pin in the APIM validate-azure-ad-token policy (empty = validate tenant + audience only). See NETWORKING.md.')
param gatewayCallerAppId string = ''

// Create a short, unique suffix, that will be unique to each resource group
var uniqueSuffix = substring(uniqueString('${resourceGroup().id}'), 0, 4)
var accountName = toLower('${aiServices}${uniqueSuffix}')

@description('Name for your project resource.')
param firstProjectName string = 'project'

@description('This project will be a sub-resource of your account')
param projectDescription string = 'A project for the AI Foundry account with network secured deployed Agent'

@description('The display name of the project')
param displayName string = 'network secured agent project'

// Virtual Network parameters
@description('Virtual Network base name')
param vnetName string = 'agent-vnet-test'

@description('The name of Agents Subnet to create for agents')
param agentSubnetName string = 'agent-subnet'

@description('The name of Private Endpoint subnet')
param peSubnetName string = 'pe-subnet'

//Existing standard Agent required resources
@description('The AI Search Service full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param aiSearchResourceId string = ''
@description('The AI Storage Account full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param azureStorageAccountResourceId string = ''
@description('The Cosmos DB Account full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param azureCosmosDBAccountResourceId string = ''

@secure()
@minLength(15)
param vmAdminPassword string

param vmAdminUsername string

@description('Object mapping DNS zone names to their resource group, or empty string to indicate creation')
param existingDnsZones object = {
  'privatelink.services.ai.azure.com': ''
  'privatelink.openai.azure.com': ''
  'privatelink.cognitiveservices.azure.com': ''
  'privatelink.search.windows.net': ''
  'privatelink.blob.${environment().suffixes.storage}': ''
  'privatelink.documents.azure.com': ''
  'privatelink.vaultcore.azure.net': ''
}

@description('Zone Names for Validation of existing Private Dns Zones')
param dnsZoneNames array = [
  'privatelink.services.ai.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.search.windows.net'
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.documents.azure.com'
  'privatelink.vaultcore.azure.net'
]

var projectName = toLower('${firstProjectName}${uniqueSuffix}')
var cosmosDBName = toLower('${aiServices}${uniqueSuffix}cosmosdb')
var aiSearchName = toLower('${aiServices}${uniqueSuffix}search')
var azureStorageName = toLower('${aiServices}${uniqueSuffix}stg')
var keyVaultName = toLower('${aiServices}${uniqueSuffix}kv')

// Check if existing resources have been passed in
var storagePassedIn = azureStorageAccountResourceId != ''
var searchPassedIn = aiSearchResourceId != ''
var cosmosPassedIn = azureCosmosDBAccountResourceId != ''

var acsParts = split(aiSearchResourceId, '/')
var aiSearchServiceSubscriptionId = searchPassedIn ? acsParts[2] : subscription().subscriptionId
var aiSearchServiceResourceGroupName = searchPassedIn ? acsParts[4] : resourceGroup().name

var cosmosParts = split(azureCosmosDBAccountResourceId, '/')
var cosmosDBSubscriptionId = cosmosPassedIn ? cosmosParts[2] : subscription().subscriptionId
var cosmosDBResourceGroupName = cosmosPassedIn ? cosmosParts[4] : resourceGroup().name

var storageParts = split(azureStorageAccountResourceId, '/')
var azureStorageSubscriptionId = storagePassedIn ? storageParts[2] : subscription().subscriptionId
var azureStorageResourceGroupName = storagePassedIn ? storageParts[4] : resourceGroup().name

@description('The name of the project capability host to be created')
param projectCapHost string = 'caphostproj'

var appServicePlanName = toLower('${uniqueSuffix}-asp')

var logAnalyticsName = toLower('${uniqueSuffix}-la')
var appInsightsName = toLower('${uniqueSuffix}-appi')
var acrName = toLower('${uniqueSuffix}acr')

resource lanalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  kind: 'web'
  location: location
  name: appInsightsName
  properties: {
    Application_Type: 'web'
    Flow_Type: 'BlueField'
    WorkspaceResourceId: lanalytics.id
    RetentionInDays: 30
  }
}

// ==================== NETWORKING (Hub-Spoke) ====================

// Step 1: Deploy Hub VNet + DNS Resolver
module hubNetwork 'modules-network-secured/network-agent-vnet.bicep' = {
  name: 'hub-network-${uniqueSuffix}-deployment'
  params: {
    location: location
    vnetName: vnetName
  }
}

// Step 2: Deploy Firewall into Hub VNet
var firewallPolicyName = '${uniqueSuffix}fwallpol'

// CIDRs allowed to call the agent ingress (/invoke path). The YARP proxy is an
// App Service VNet-integrated into the App Service spoke's delegated subnet, so
// its outbound calls to the agent originate from that /24. Kept tight — only the
// delegated subnet, not the whole App Service spoke VNet. Derived from the
// App Service spoke default address space (10.1.0.0/16, subnet 0).
var appServiceSpokeAddressPrefix = '10.1.0.0/16'
var agentInboundAllowedCidrs = [
  cidrSubnet(appServiceSpokeAddressPrefix, 24, 0)
]

// Foundry spoke address space (module default). Agent subnet is locked down at the
// firewall; the dev VM subnet stays unrestricted alongside the App Service spoke.
var foundrySpokeAddressPrefix = '10.2.0.0/16'
var agentSubnetCidr = cidrSubnet(foundrySpokeAddressPrefix, 24, 0)
var vmSubnetCidr = cidrSubnet(foundrySpokeAddressPrefix, 24, 2)
var deploymentScriptsSubnetCidr = cidrSubnet(foundrySpokeAddressPrefix, 24, 3)
var firewallUnrestrictedSourceCidrs = [
  vmSubnetCidr
  appServiceSpokeAddressPrefix
  deploymentScriptsSubnetCidr
]

// Model-gateway spoke (optional). CIDRs are deterministic so they can be passed to
// the firewall without depending on the spoke VNet module (avoids a dependency cycle:
// the spoke VNet needs the firewall private IP, the firewall needs these CIDRs).
var modelGatewaySpokeAddressPrefix = '10.3.0.0/16'
var modelGatewayApimSubnetCidr = cidrSubnet(modelGatewaySpokeAddressPrefix, 24, 0)
var modelGatewayPeSubnetCidr = cidrSubnet(modelGatewaySpokeAddressPrefix, 24, 1)
var providerAccountName = toLower('gwprovider${uniqueSuffix}')
var apimName = 'apim-${uniqueSuffix}-modelgw'
var modelGatewayConnectionName = 'model-gateway'
var providerBackendBaseUrl = 'https://${providerAccountName}.openai.azure.com/openai'

module firewall 'modules-network-secured/firewall.bicep' = {
  name: '${deployment().name}-fwall'
  params: {
    firewallPipName: '${uniqueSuffix}-fwall-pip'
    firewallMgmtPipName: '${uniqueSuffix}-fwallmgmt-pip'
    firewallName: '${uniqueSuffix}-fwall'
    firewallPolicyName: firewallPolicyName
    firewallSubnetId: hubNetwork.outputs.firewallSubnetId
    firewallManagementSubnetId: hubNetwork.outputs.firewallManagementSubnetId
    location: location
    logAnalyticsId: lanalytics.id
    yarpProxyFqdn: 'yarp-${appServicePlanName}.azurewebsites.net'
    agentSubnetCidr: agentSubnetCidr
    unrestrictedSourceCidrs: firewallUnrestrictedSourceCidrs
  }
}

// Step 3: Deploy Foundry Spoke VNet (needs firewall IP + DNS resolver IP)
module foundrySpokeVnet 'modules-network-secured/foundry-spoke-vnet.bicep' = {
  name: 'foundry-spoke-${uniqueSuffix}-deployment'
  params: {
    location: location
    vnetName: '${vnetName}-foundry-spoke'
    agentSubnetName: agentSubnetName
    peSubnetName: peSubnetName
    firewallPrivateIp: firewall.outputs.firewallPrivateIp
    dnsServerIp: hubNetwork.outputs.dnsResolverInboundIp
    agentInboundAllowedCidrs: agentInboundAllowedCidrs
    modelGatewayPeCidr: enableModelGateway ? modelGatewayPeSubnetCidr : ''
  }
}

// Step 4: Deploy App Service Spoke VNet (needs firewall IP + DNS resolver IP)
module appServiceSpokeVnet 'modules-network-secured/appservice-spoke-vnet.bicep' = {
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
module agentFlowLogs 'modules-network-secured/agent-flow-logs.bicep' = {
  name: 'agent-flow-logs-${uniqueSuffix}-deployment'
  scope: resourceGroup('NetworkWatcherRG')
  params: {
    location: location
    targetSubnetId: foundrySpokeVnet.outputs.agentSubnetId
    flowLogsStorageId: flowLogsStorage.id
    flowLogName: '${uniqueSuffix}-agent-subnet-flowlog'
    workspaceResourceId: lanalytics.id
    workspaceGuid: lanalytics.properties.customerId
    workspaceRegion: location
  }
}


// Step 5: VNet Peerings (Hub ↔ Foundry Spoke)
module hubToFoundryPeering 'modules-network-secured/vnet-peering.bicep' = {
  name: 'hub-foundry-peering-${uniqueSuffix}'
  params: {
    hubVnetName: hubNetwork.outputs.hubVnetName
    spokeVnetName: foundrySpokeVnet.outputs.virtualNetworkName
    hubVnetId: hubNetwork.outputs.hubVnetId
    spokeVnetId: foundrySpokeVnet.outputs.virtualNetworkId
  }
}

// Step 6: VNet Peerings (Hub ↔ App Service Spoke)
module hubToAppServicePeering 'modules-network-secured/vnet-peering.bicep' = {
  name: 'hub-appservice-peering-${uniqueSuffix}'
  params: {
    hubVnetName: hubNetwork.outputs.hubVnetName
    spokeVnetName: appServiceSpokeVnet.outputs.virtualNetworkName
    hubVnetId: hubNetwork.outputs.hubVnetId
    spokeVnetId: appServiceSpokeVnet.outputs.virtualNetworkId
  }
}

// ==================== AI SERVICES ====================

/*
  Create the AI Services account and gpt-4o model deployment
*/
module aiAccount 'modules-network-secured/ai-account-identity.bicep' = {
  name: 'ai-${accountName}-${uniqueSuffix}-deployment'
  params: {
    // workspace organization
    accountName: accountName
    location: location
    modelName: modelName
    modelFormat: modelFormat
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity
    agentSubnetId: foundrySpokeVnet.outputs.agentSubnetId
    logAnalyticsWorkspaceId: lanalytics.id
    appInsightsConnectionString: appInsights.properties.ConnectionString
    appInsightsResourceId: appInsights.id
    mcpServerName: 'mcp-${appServicePlanName}.azurewebsites.net'
    keyVaultName: keyVaultName
  }
}
/*
  Validate existing resources
*/
module validateExistingResources 'modules-network-secured/validate-existing-resources.bicep' = {
  name: 'validate-existing-resources-${uniqueSuffix}-deployment'
  params: {
    aiSearchResourceId: aiSearchResourceId
    azureStorageAccountResourceId: azureStorageAccountResourceId
    azureCosmosDBAccountResourceId: azureCosmosDBAccountResourceId
    existingDnsZones: existingDnsZones
    dnsZoneNames: dnsZoneNames
  }
}

// ==================== KEY VAULT (CMK) ====================

module keyVault 'modules-network-secured/keyvault.bicep' = {
  name: 'keyvault-${uniqueSuffix}-deployment'
  params: {
    keyVaultName: keyVaultName
    location: location
    logAnalyticsId: lanalytics.id
  }
}

// Create new agent dependent resources (Storage, CosmosDB, AI Search, App Service)
module aiDependencies 'modules-network-secured/standard-dependent-resources.bicep' = {
  name: 'dependencies-${uniqueSuffix}-deployment'
  params: {
    location: location
    azureStorageName: azureStorageName
    aiSearchName: aiSearchName
    cosmosDBName: cosmosDBName

    // AI Search Service parameters
    aiSearchResourceId: aiSearchResourceId
    aiSearchExists: validateExistingResources.outputs.aiSearchExists

    // Storage Account
    azureStorageAccountResourceId: azureStorageAccountResourceId
    azureStorageExists: validateExistingResources.outputs.azureStorageExists

    // Cosmos DB Account
    cosmosDBResourceId: azureCosmosDBAccountResourceId
    cosmosDBExists: validateExistingResources.outputs.cosmosDBExists

    logAnalyticsId: lanalytics.id
    appServicePlanName: appServicePlanName

    appInsightsName: appInsightsName
    appServiceDelegationSubnetId: appServiceSpokeVnet.outputs.appServiceDelegatedSubnetId

    //wire up the YARP proxy
    foundryName: aiAccount.outputs.accountName

  }
}

resource storage 'Microsoft.Storage/storageAccounts@2022-05-01' existing = {
  name: aiDependencies.outputs.azureStorageName
  scope: resourceGroup(azureStorageSubscriptionId, azureStorageResourceGroupName)
}

resource aiSearch 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: aiDependencies.outputs.aiSearchName
  scope: resourceGroup(
    aiDependencies.outputs.aiSearchServiceSubscriptionId,
    aiDependencies.outputs.aiSearchServiceResourceGroupName
  )
}

resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: aiDependencies.outputs.cosmosDBName
  scope: resourceGroup(cosmosDBSubscriptionId, cosmosDBResourceGroupName)
}

module acr './modules-network-secured/acr.bicep' = {
  name: 'acr-${uniqueSuffix}-deployment'
  params: {
    location: location
    acrName: acrName
    logAnalyticsWorkspaceId: lanalytics.id
  }
}

// ==================== CMK RBAC & ENCRYPTION ====================

// Assign Key Vault Crypto Service Encryption User to service identities (post-creation)
module keyVaultRoleAssignments 'modules-network-secured/keyvault-role-assignments.bicep' = {
  name: 'keyvault-rbac-${uniqueSuffix}-deployment'
  params: {
    keyVaultName: keyVault.outputs.keyVaultName
    aiServicesPrincipalId: aiAccount.outputs.accountPrincipalId
    storagePrincipalId: aiDependencies.outputs.storagePrincipalId
    aiSearchPrincipalId: aiDependencies.outputs.aiSearchPrincipalId
    aiServicesProjectPrincipalId: aiProject.outputs.projectPrincipalId
  }
}

// Update AI Services account with CMK encryption (must be after RBAC assignment)
module aiAccountEncryption 'modules-network-secured/ai-account-encryption.bicep' = {
  name: 'ai-encryption-${uniqueSuffix}-deployment'
  params: {
    accountName: aiAccount.outputs.accountName
    location: location
    keyVaultUri: keyVault.outputs.keyVaultUri
    keyName: keyVault.outputs.keyName
    keyVersion: last(split(keyVault.outputs.keyUriWithVersion, '/'))
    agentSubnetId: foundrySpokeVnet.outputs.agentSubnetId
    keyVaultName: keyVault.outputs.keyVaultName
  }
  dependsOn: [
    keyVaultRoleAssignments
  ]
}

// Update Storage Account with CMK encryption (must be after RBAC assignment)
var noZRSRegions = ['southindia', 'westus', 'northcentralus']
var storageSkuName = contains(noZRSRegions, location) ? 'Standard_GRS' : 'Standard_ZRS'

module storageEncryption 'modules-network-secured/storage-encryption.bicep' = if (!storagePassedIn) {
  name: 'storage-encryption-${uniqueSuffix}-deployment'
  params: {
    storageName: aiDependencies.outputs.azureStorageName
    location: location
    keyVaultUri: keyVault.outputs.keyVaultUri
    keyVaultKeyName: keyVault.outputs.keyName
    skuName: storageSkuName
  }
  dependsOn: [
    keyVaultRoleAssignments
  ]
}

// ==================== PRIVATE ENDPOINTS & DNS ====================

module privateEndpointAndDNS 'modules-network-secured/private-endpoint-and-dns.bicep' = {
  name: '${uniqueSuffix}-private-endpoint'
  params: {
    aiAccountName: aiAccount.outputs.accountName
    aiSearchName: aiDependencies.outputs.aiSearchName
    storageName: aiDependencies.outputs.azureStorageName
    cosmosDBName: aiDependencies.outputs.cosmosDBName

    // Hub VNet (DNS zones linked here for resolver)
    hubVnetName: hubNetwork.outputs.hubVnetName

    // Foundry Spoke (Foundry PEs go here)
    foundrySpokeVnetName: foundrySpokeVnet.outputs.virtualNetworkName
    foundryPeSubnetName: foundrySpokeVnet.outputs.peSubnetName

    // App Service Spoke (App Service PEs go here)
    appServiceSpokeVnetName: appServiceSpokeVnet.outputs.virtualNetworkName
    appServicePeSubnetName: appServiceSpokeVnet.outputs.peSubnetName

    suffix: uniqueSuffix
    cosmosDBSubscriptionId: cosmosDBSubscriptionId
    cosmosDBResourceGroupName: cosmosDBResourceGroupName
    aiSearchSubscriptionId: aiSearchServiceSubscriptionId
    aiSearchResourceGroupName: aiSearchServiceResourceGroupName
    storageAccountResourceGroupName: azureStorageResourceGroupName
    storageAccountSubscriptionId: azureStorageSubscriptionId
    existingDnsZones: existingDnsZones
    appServiceWebAppNames: [aiDependencies.outputs.yarpWebAppName, aiDependencies.outputs.mcpWebAppName]
    acrName: acr.outputs.acrName
    keyVaultName: keyVault.outputs.keyVaultName
  }
  dependsOn: [
    aiSearch
    storage
    cosmosDB
    hubToFoundryPeering
    hubToAppServicePeering
  ]
}

// ==================== AI PROJECT ====================

/*
  Creates a new project (sub-resource of the AI Services account)
*/
module aiProject 'modules-network-secured/ai-project-identity.bicep' = {
  name: 'ai-${projectName}-${uniqueSuffix}-deployment'
  params: {
    // workspace organization
    projectName: projectName
    projectDescription: projectDescription
    displayName: displayName
    location: location

    aiSearchName: aiDependencies.outputs.aiSearchName
    aiSearchServiceResourceGroupName: aiDependencies.outputs.aiSearchServiceResourceGroupName
    aiSearchServiceSubscriptionId: aiDependencies.outputs.aiSearchServiceSubscriptionId

    cosmosDBName: aiDependencies.outputs.cosmosDBName
    cosmosDBSubscriptionId: aiDependencies.outputs.cosmosDBSubscriptionId
    cosmosDBResourceGroupName: aiDependencies.outputs.cosmosDBResourceGroupName

    azureStorageName: aiDependencies.outputs.azureStorageName
    azureStorageSubscriptionId: aiDependencies.outputs.azureStorageSubscriptionId
    azureStorageResourceGroupName: aiDependencies.outputs.azureStorageResourceGroupName
    // dependent resources
    accountName: aiAccount.outputs.accountName

    logAnalyticsWorkspaceId: lanalytics.id

    mcpServerName: 'testweathermcpserver'
    mcpUrl: 'https://${aiDependencies.outputs.mcpWebAppFqdn}/'

  }
  dependsOn: [
    privateEndpointAndDNS
    cosmosDB
    aiSearch
    storage
  ]
}

module formatProjectWorkspaceId 'modules-network-secured/format-project-workspace-id.bicep' = {
  name: 'format-project-workspace-id-${uniqueSuffix}-deployment'
  params: {
    projectWorkspaceId: aiProject.outputs.projectWorkspaceId
  }
}

/*
  Assigns the project SMI the storage blob data contributor role on the storage account
*/
module storageAccountRoleAssignment 'modules-network-secured/azure-storage-account-role-assignment.bicep' = {
  name: 'storage-ra-${uniqueSuffix}-deployment'
  scope: resourceGroup(azureStorageSubscriptionId, azureStorageResourceGroupName)
  params: {
    azureStorageName: aiDependencies.outputs.azureStorageName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    storage
    privateEndpointAndDNS
  ]
}

/*
  Assigns the project SMI Reader role on Application Insights.
  This supports running Evaluations on existing traces.
*/
module appInsightsRoleAssignment 'modules-network-secured/app-insights-role-assignment.bicep' = {
  name: 'appi-ra-${uniqueSuffix}-deployment'
  params: {
    appInsightsName: appInsightsName
    accountPrincipalId: aiAccount.outputs.accountPrincipalId
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
}

/*
  Assigns the project SMI Container Registry Repository Reader role on ACR.
*/
module acrRoleAssignment 'modules-network-secured/acr-role-assignment.bicep' = {
  name: 'acr-ra-${uniqueSuffix}-deployment'
  params: {
    acrName: acr.outputs.acrName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
}

/*
  Assigns Foundry User role to the project SMI on the Foundry project resource.
*/
module foundryProjectRoleAssignment 'modules-network-secured/foundry-project-role-assignment.bicep' = {
  name: 'foundry-project-ra-${uniqueSuffix}-deployment'
  params: {
    accountName: aiAccount.outputs.accountName
    projectName: aiProject.outputs.projectName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
}

// The Comos DB Operator role must be assigned before the caphost is created
module cosmosAccountRoleAssignments 'modules-network-secured/cosmosdb-account-role-assignment.bicep' = {
  name: 'cosmos-account-ra-${uniqueSuffix}-deployment'
  scope: resourceGroup(cosmosDBSubscriptionId, cosmosDBResourceGroupName)
  params: {
    cosmosDBName: aiDependencies.outputs.cosmosDBName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    cosmosDB
    privateEndpointAndDNS
  ]
}

// This role can be assigned before or after the caphost is created
module aiSearchRoleAssignments 'modules-network-secured/ai-search-role-assignments.bicep' = {
  name: 'ai-search-ra-${uniqueSuffix}-deployment'
  scope: resourceGroup(aiSearchServiceSubscriptionId, aiSearchServiceResourceGroupName)
  params: {
    aiSearchName: aiDependencies.outputs.aiSearchName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    aiSearch
    privateEndpointAndDNS
  ]
}

// This module creates the capability host for the project and account
module addProjectCapabilityHost 'modules-network-secured/add-project-capability-host.bicep' = {
  name: 'capabilityHost-configuration-${uniqueSuffix}-deployment'
  params: {
    accountName: aiAccount.outputs.accountName
    projectName: aiProject.outputs.projectName
    cosmosDBConnection: aiProject.outputs.cosmosDBConnection
    azureStorageConnection: aiProject.outputs.azureStorageConnection
    aiSearchConnection: aiProject.outputs.aiSearchConnection
    projectCapHost: projectCapHost
  }
  dependsOn: [
    aiSearch
    storage
    cosmosDB
    privateEndpointAndDNS
    cosmosAccountRoleAssignments
    storageAccountRoleAssignment
    aiSearchRoleAssignments
  ]
}

// The Storage Blob Data Owner role must be assigned after the caphost is created
module storageContainersRoleAssignment 'modules-network-secured/blob-storage-container-role-assignments.bicep' = {
  name: 'storage-containers-ra-${uniqueSuffix}-deployment'
  scope: resourceGroup(azureStorageSubscriptionId, azureStorageResourceGroupName)
  params: {
    aiProjectPrincipalId: aiProject.outputs.projectPrincipalId
    storageName: aiDependencies.outputs.azureStorageName
    workspaceId: formatProjectWorkspaceId.outputs.projectWorkspaceIdGuid
  }
  dependsOn: [
    addProjectCapabilityHost
  ]
}

// The Cosmos Built-In Data Contributor role must be assigned after the caphost is created
module cosmosContainerRoleAssignments 'modules-network-secured/cosmos-container-role-assignments.bicep' = {
  name: 'cosmos-container-ra-${uniqueSuffix}-deployment'
  scope: resourceGroup(cosmosDBSubscriptionId, cosmosDBResourceGroupName)
  params: {
    cosmosAccountName: aiDependencies.outputs.cosmosDBName
    projectWorkspaceId: formatProjectWorkspaceId.outputs.projectWorkspaceIdGuid
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    addProjectCapabilityHost
    storageContainersRoleAssignment
  ]
}

// ==================== VM + BASTION (in Foundry Spoke) ====================

module vmModule 'modules-network-secured/vm.bicep' = {
  name: 'vm-deployment-${uniqueSuffix}'
  params: {
    location: location
    vmName: 'test-vm-${uniqueSuffix}'
    virtualNetworkName: foundrySpokeVnet.outputs.virtualNetworkName
    subnetName: foundrySpokeVnet.outputs.vmSubnetName
    adminPassword: vmAdminPassword
    adminUsername: vmAdminUsername
  }
  dependsOn: [
    privateEndpointAndDNS
  ]
}

// ==================== MODEL GATEWAY (optional spoke) ====================

/*
  Optional enterprise model gateway. When enableModelGateway is true this deploys,
  in a NEW spoke (10.3.0.0/16) peered only to the hub:
    - an APIM Standard v2 instance (inbound PE + outbound VNet integration),
    - a locked-down "provider" AI Foundry that actually hosts the model,
  then advertises APIM to the primary Foundry project as an ApiManagement
  connection (ProjectManagedIdentity / keyless). A second agent is seeded that
  uses the '<connection>/<model>' reference. The agent reaches APIM's inbound PE
  by force-tunnelling through the Azure Firewall (no spoke-to-spoke peering).
*/

// Step 7: model-gateway spoke VNet
module modelGatewaySpokeVnet 'modules-network-secured/model-gateway/model-gateway-spoke-vnet.bicep' = if (enableModelGateway) {
  name: 'model-gateway-spoke-${uniqueSuffix}-deployment'
  params: {
    location: location
    vnetName: '${vnetName}-model-gateway-spoke'
    vnetAddressPrefix: modelGatewaySpokeAddressPrefix
    firewallPrivateIp: firewall.outputs.firewallPrivateIp
    dnsServerIp: hubNetwork.outputs.dnsResolverInboundIp
  }
}

// Step 8: peer hub <-> model-gateway spoke
module hubToModelGatewayPeering 'modules-network-secured/vnet-peering.bicep' = if (enableModelGateway) {
  name: 'hub-model-gateway-peering-${uniqueSuffix}'
  params: {
    hubVnetName: hubNetwork.outputs.hubVnetName
    spokeVnetName: modelGatewaySpokeVnet.outputs.virtualNetworkName
    hubVnetId: hubNetwork.outputs.hubVnetId
    spokeVnetId: modelGatewaySpokeVnet.outputs.virtualNetworkId
  }
}

// Provider AI Foundry (the "real" model provider) — minimal, locked-down.
module providerFoundry 'modules-network-secured/model-gateway/provider-foundry.bicep' = if (enableModelGateway) {
  name: 'provider-foundry-${uniqueSuffix}-deployment'
  params: {
    accountName: providerAccountName
    location: location
    modelName: gatewayModelName
    modelFormat: gatewayModelFormat
    modelVersion: gatewayModelVersion
    modelSkuName: gatewayModelSkuName
    modelCapacity: gatewayModelCapacity
    logAnalyticsWorkspaceId: lanalytics.id
  }
}

// APIM Standard v2 in the gateway spoke.
module apim 'modules-network-secured/model-gateway/apim.bicep' = if (enableModelGateway) {
  name: 'model-gateway-apim-${uniqueSuffix}-deployment'
  params: {
    apimName: apimName
    location: location
    apimOutboundSubnetId: modelGatewaySpokeVnet.outputs.apimSubnetId
    logAnalyticsWorkspaceId: lanalytics.id
    appInsightsResourceId: appInsights.id
    appInsightsConnectionString: appInsights.properties.ConnectionString
  }
}

// Private endpoints (APIM inbound + provider Foundry) + DNS in the gateway spoke.
module modelGatewayPrivateEndpoints 'modules-network-secured/model-gateway/model-gateway-private-endpoints.bicep' = if (enableModelGateway) {
  name: 'model-gateway-pe-${uniqueSuffix}-deployment'
  params: {
    location: location
    suffix: uniqueSuffix
    apimId: apim.outputs.apimId
    apimName: apim.outputs.apimName
    providerAccountId: providerFoundry.outputs.accountId
    providerAccountName: providerFoundry.outputs.accountName
    peSubnetId: modelGatewaySpokeVnet.outputs.peSubnetId
    hubVnetId: hubNetwork.outputs.hubVnetId
    apimDnsZoneResourceGroup: contains(existingDnsZones, 'privatelink.azure-api.net') ? existingDnsZones['privatelink.azure-api.net'] : ''
    aiServicesDnsZoneResourceGroup: contains(existingDnsZones, 'privatelink.services.ai.azure.com') ? existingDnsZones['privatelink.services.ai.azure.com'] : ''
    openAiDnsZoneResourceGroup: contains(existingDnsZones, 'privatelink.openai.azure.com') ? existingDnsZones['privatelink.openai.azure.com'] : ''
    cognitiveServicesDnsZoneResourceGroup: contains(existingDnsZones, 'privatelink.cognitiveservices.azure.com') ? existingDnsZones['privatelink.cognitiveservices.azure.com'] : ''
  }
  dependsOn: [
    privateEndpointAndDNS
  ]
}

// Grant APIM MI Cognitive Services User on the provider Foundry (backend MI auth).
module apimProviderRoleAssignment 'modules-network-secured/model-gateway/apim-provider-role-assignment.bicep' = if (enableModelGateway) {
  name: 'model-gateway-apim-rbac-${uniqueSuffix}-deployment'
  params: {
    providerAccountName: providerFoundry.outputs.accountName
    apimPrincipalId: apim.outputs.apimPrincipalId
  }
}

// APIM inference API + policy (inbound token validation, backend + MI auth).
module apimApiPolicy 'modules-network-secured/model-gateway/apim-api-policy.bicep' = if (enableModelGateway) {
  name: 'model-gateway-apim-api-${uniqueSuffix}-deployment'
  params: {
    apimName: apim.outputs.apimName
    backendBaseUrl: providerBackendBaseUrl
    providerAccountResourceId: providerFoundry.outputs.accountId
    projectMiClientId: gatewayCallerAppId
    callerProjectResourceId: aiProject.outputs.projectId
  }
  dependsOn: [
    apimProviderRoleAssignment
  ]
}

// Advertise APIM to the primary Foundry project as an ApiManagement connection.
module apimConnection 'modules-network-secured/model-gateway/apim-connection.bicep' = if (enableModelGateway) {
  name: 'model-gateway-connection-${uniqueSuffix}-deployment'
  params: {
    aiFoundryName: aiAccount.outputs.accountName
    projectName: aiProject.outputs.projectName
    connectionName: modelGatewayConnectionName
    apimGatewayUrl: apim.outputs.gatewayUrl
    apiPath: apimApiPolicy.outputs.apiPath
    exposedModelName: gatewayModelName
  }
  dependsOn: [
    addProjectCapabilityHost
  ]
}

// Phase 2 lockdown: flip APIM publicNetworkAccess to 'Disabled' now that the inbound
// private endpoint exists (APIM forbids 'Disabled' at create time). Runs after the PE
// and after the API/policy children so it never races their creation.
module apimLockdown 'modules-network-secured/model-gateway/apim-lockdown.bicep' = if (enableModelGateway) {
  name: 'model-gateway-apim-lockdown-${uniqueSuffix}-deployment'
  params: {
    apimName: apim.outputs.apimName
    location: location
    apimOutboundSubnetId: modelGatewaySpokeVnet.outputs.apimSubnetId
  }
  dependsOn: [
    modelGatewayPrivateEndpoints
    apimApiPolicy
  ]
}

// Model-gateway firewall rules (agent -> APIM inbound PE, APIM subnet platform egress).
// Deliberately sequenced AFTER the APIM deployment: APIM Standard v2 takes ~15-45 min to
// provision, which leaves the firewall long-idle after firewall.bicep's defaultRuleGroup
// PUT before this second rule-collection-group PUT lands on the same policy. This avoids
// the transient "faulted referenced firewalls" fault Basic-tier firewalls hit when two
// rule-collection-group PUTs arrive back-to-back.
module modelGatewayFirewallRules 'modules-network-secured/model-gateway/model-gateway-firewall-rules.bicep' = if (enableModelGateway) {
  name: 'model-gateway-fwall-rules-${uniqueSuffix}-deployment'
  params: {
    firewallPolicyName: firewallPolicyName
    agentSubnetCidr: agentSubnetCidr
    modelGatewayPeSubnetCidr: modelGatewayPeSubnetCidr
    modelGatewayApimSubnetCidr: modelGatewayApimSubnetCidr
  }
  dependsOn: [
    firewall
    apim
  ]
}

// ==================== SEED AGENTS ====================

// Runs a deployment-script container inside the private VNet to call the Foundry
// Agents API and provision the initial set of agents. The container is ephemeral —
// it runs once, seeds the agents, then ARM cleans it up after retentionInterval.
module seedAgents 'modules-network-secured/seed-agents-script.bicep' = {
  name: 'seed-agents-${uniqueSuffix}'
  params: {
    location: location
    foundryProjectEndpoint: '${aiProject.outputs.projectEndpoint}/'
    modelDeploymentName: modelName
    vmName: vmModule.outputs.vmName
    vmPrincipalId: vmModule.outputs.vmPrincipalId
    accountName: aiAccount.outputs.accountName
    projectName: aiProject.outputs.projectName
    enableSecondAgent: enableModelGateway
    secondAgentModel: apimConnection.?outputs.agentModelReference ?? ''
  }
  dependsOn: [
    addProjectCapabilityHost
    cosmosContainerRoleAssignments
    storageContainersRoleAssignment
    privateEndpointAndDNS
    vmModule
  ]
}
