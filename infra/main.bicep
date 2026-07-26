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
param modelName string = 'gpt-5.4'
@description('The provider of your model')
param modelFormat string = 'OpenAI'
@description('The version of your model')
param modelVersion string = '2026-03-05'
@description('The sku of your model deployment')
param modelSkuName string = 'GlobalStandard'
@description('The tokens per minute (TPM) of your model deployment')
param modelCapacity int = 30

// ==================== MODEL GATEWAY ====================
// The enterprise model gateway is always deployed: an APIM Standard v2 instance + a "real"
// provider AI Foundry in a NEW spoke, advertised to the primary Foundry project as an
// ApiManagement connection.

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

// ==================== TEAMS / M365 PUBLISH (optional) ====================
@description('Deploy the Teams / M365 Copilot inbound publish path: a new APIM API that forwards to the agent activityProtocol endpoint, plus the YARP proxy flipped public (IP-restricted to the Bot Channel Adapter ranges). The Azure Bot Service + Step 3/4 publish are performed by the postdeploy hook (scripts/publish-teams.ps1). Default true.')
param enableTeamsPublish bool = true

@description('Names of the seeded agents to publish to Teams / M365. Each gets its own Azure Bot Service whose messaging endpoint is https://<yarp>/teams/<agentName>; the single path-routed APIM Teams API rewrites to each agent activityProtocol endpoint. Defaults to all three seeded agents.')
param teamsPublishAgentNames array = [
  'hello-world-agent'
  'gateway-model-agent'
  'teams-agent'
]

@description('Bot Microsoft App IDs (= each published agent identity principal_id) allowed as APIM validate-jwt audiences. Empty = validate the Bot Framework issuer only; the publish hook rebuilds the full audience allowlist live once the agents are seeded.')
param teamsBotAppIds array = []

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

@secure()
@minLength(15)
param vmAdminPassword string

param vmAdminUsername string

@description('''
Deploy the OPTIONAL Windows dev VM. Its only purpose is the human "RDP in and run
Edge to inspect the environment behind the firewall" experience. All automation
(agent seeding + the self-hosted Actions runner) runs on the always-on Linux
worker VM, so set this to false in CI-only environments to skip the Windows
licence and compute cost.
''')
param deployWindowsVm bool = true

@description('''
Deploy Azure Bastion. Bastion exists for INTERACTIVE human access: it is the only way
to reach the Windows dev VM (RDP), so this DEFAULTS to deployWindowsVm — turn the
Windows VM off and Bastion goes with it. The Linux worker VM needs no interactive
path (seeding goes through `az vm run-command`, the Actions runner registers outbound),
so a CI-only environment gets neither. Deliberately NOT in main.parameters.json so the
derived default applies; override it in a .bicepparam if you want Bastion SSH into the
Linux VM without the Windows VM.
''')
param deployBastion bool = deployWindowsVm

@description('''
GitHub repo URL (https://github.com/owner/repo) to register a self-hosted Actions
runner on the Linux worker VM against. Leave EMPTY (default) to skip runner
installation. When set, the VM installs a runner as a systemd service, reading a
fine-grained PAT from Key Vault via its managed identity. See docs/github-runner.md.
''')
param githubRunnerRepoUrl string = ''


@description('Name of the Key Vault secret holding the runner PAT (Administration: read & write). Seeded manually.')
param githubRunnerPatSecretName string = 'gh-runner-pat'

@description('''
Fine-grained GitHub PAT (Administration: read & write) for the self-hosted runner.
Written into Key Vault by Bicep (control-plane write, works despite the private KV
firewall). Sourced from ${GITHUB_RUNNER_PAT} (empty by default). Set it with
`azd env set GITHUB_RUNNER_PAT <pat>`; you may clear it after provisioning — the KV
secret persists. Leave empty to reuse an already-seeded secret.
''')
@secure()
param githubRunnerPat string = ''

@description('Comma-separated labels applied to the self-hosted runner.')
param githubRunnerLabels string = 'vnet,foundry-private'

var projectName = toLower('${firstProjectName}${uniqueSuffix}')
var cosmosDBName = toLower('${aiServices}${uniqueSuffix}cosmosdb')
var aiSearchName = toLower('${aiServices}${uniqueSuffix}search')
var azureStorageName = toLower('${aiServices}${uniqueSuffix}stg')
var keyVaultName = toLower('${aiServices}${uniqueSuffix}kv')

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
module hubNetwork 'modules/network/network-agent-vnet.bicep' = {
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
var appServiceDelegatedSubnetCidr = cidrSubnet(appServiceSpokeAddressPrefix, 24, 0)
// App Service spoke PE subnet — hosts the MCP web app inbound private endpoint. The agent
// subnet is allowed to reach it (NSG + firewall) and its return path is force-tunnelled back
// through the firewall (appservice-spoke-vnet.bicep pe-subnet UDR).
var appServicePeSubnetCidr = cidrSubnet(appServiceSpokeAddressPrefix, 24, 1)
var agentInboundAllowedCidrs = [
  appServiceDelegatedSubnetCidr
]

// Foundry spoke address space (module default). Agent subnet is locked down at the
// firewall; the dev VM subnet stays unrestricted alongside the App Service spoke.
var foundrySpokeAddressPrefix = '10.2.0.0/16'
var agentSubnetCidr = cidrSubnet(foundrySpokeAddressPrefix, 24, 0)
var foundryPeSubnetCidr = cidrSubnet(foundrySpokeAddressPrefix, 24, 1)
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
// APIM Standard v2 gateway URL is deterministic from the name. Derived (not read from the
// apim module output) so the YARP proxy — which is provisioned BEFORE APIM in the graph —
// can be pointed at it without a dependency cycle.
var apimGatewayUrl = 'https://${apimName}.azure-api.net'
var modelGatewayConnectionName = 'model-gateway'
var providerBackendBaseUrl = 'https://${providerAccountName}.openai.azure.com/openai'

module firewall 'modules/network/firewall.bicep' = {
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
    appServicePeSubnetCidr: appServicePeSubnetCidr
    unrestrictedSourceCidrs: firewallUnrestrictedSourceCidrs
  }
}

// Step 3: Deploy Foundry Spoke VNet (needs firewall IP + DNS resolver IP)
module foundrySpokeVnet 'modules/network/foundry-spoke-vnet.bicep' = {
  name: 'foundry-spoke-${uniqueSuffix}-deployment'
  params: {
    location: location
    vnetName: '${vnetName}-foundry-spoke'
    agentSubnetName: agentSubnetName
    peSubnetName: peSubnetName
    firewallPrivateIp: firewall.outputs.firewallPrivateIp
    dnsServerIp: hubNetwork.outputs.dnsResolverInboundIp
    agentInboundAllowedCidrs: agentInboundAllowedCidrs
    modelGatewayPeCidr: modelGatewayPeSubnetCidr
    appServicePeCidr: appServicePeSubnetCidr
    apimSubnetCidr: enableTeamsPublish ? modelGatewayApimSubnetCidr : ''
  }
}

// Step 4: Deploy App Service Spoke VNet (needs firewall IP + DNS resolver IP)
module appServiceSpokeVnet 'modules/network/appservice-spoke-vnet.bicep' = {
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
module agentFlowLogs 'modules/network/agent-flow-logs.bicep' = {
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
module hubToFoundryPeering 'modules/network/vnet-peering.bicep' = {
  name: 'hub-foundry-peering-${uniqueSuffix}'
  params: {
    hubVnetName: hubNetwork.outputs.hubVnetName
    spokeVnetName: foundrySpokeVnet.outputs.virtualNetworkName
    hubVnetId: hubNetwork.outputs.hubVnetId
    spokeVnetId: foundrySpokeVnet.outputs.virtualNetworkId
  }
}

// Step 6: VNet Peerings (Hub ↔ App Service Spoke)
module hubToAppServicePeering 'modules/network/vnet-peering.bicep' = {
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
module aiAccount 'modules/foundry/ai-account-identity.bicep' = {
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

// ==================== KEY VAULT (CMK) ====================

module keyVault 'modules/resources/keyvault.bicep' = {
  name: 'keyvault-${uniqueSuffix}-deployment'
  params: {
    keyVaultName: keyVaultName
    location: location
    logAnalyticsId: lanalytics.id
  }
}

// Create agent dependent resources (Storage, CosmosDB, AI Search, App Service)
module aiDependencies 'modules/resources/standard-dependent-resources.bicep' = {
  name: 'dependencies-${uniqueSuffix}-deployment'
  params: {
    location: location
    azureStorageName: azureStorageName
    aiSearchName: aiSearchName
    cosmosDBName: cosmosDBName

    logAnalyticsId: lanalytics.id
    appServicePlanName: appServicePlanName

    appInsightsName: appInsightsName
    appServiceDelegationSubnetId: appServiceSpokeVnet.outputs.appServiceDelegatedSubnetId

    //wire up the YARP proxy
    foundryName: aiAccount.outputs.accountName
    enableTeamsPublish: enableTeamsPublish
    apimGatewayUrl: apimGatewayUrl

  }
}

resource storage 'Microsoft.Storage/storageAccounts@2022-05-01' existing = {
  name: aiDependencies.outputs.azureStorageName
}

resource aiSearch 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: aiDependencies.outputs.aiSearchName
}

resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: aiDependencies.outputs.cosmosDBName
}

module acr './modules/resources/acr.bicep' = {
  name: 'acr-${uniqueSuffix}-deployment'
  params: {
    location: location
    acrName: acrName
    logAnalyticsWorkspaceId: lanalytics.id
  }
}

// ==================== CMK RBAC & ENCRYPTION ====================

// Assign Key Vault Crypto Service Encryption User to service identities (post-creation)
module keyVaultRoleAssignments 'modules/rbac/keyvault-role-assignments.bicep' = {
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
module aiAccountEncryption 'modules/encryption/ai-account-encryption.bicep' = {
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

module storageEncryption 'modules/encryption/storage-encryption.bicep' = {
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

module privateEndpointAndDNS 'modules/network/private-endpoint-and-dns.bicep' = {
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
    // When Teams publish is enabled the YARP proxy is public (its own FQDN + managed cert is
    // the Bot Channel Adapter entry point), so it gets NO private endpoint — only the MCP web
    // app does. Otherwise both get private endpoints (legacy private-only posture).
    appServiceWebAppNames: enableTeamsPublish
      ? [aiDependencies.outputs.mcpWebAppName]
      : [aiDependencies.outputs.yarpWebAppName, aiDependencies.outputs.mcpWebAppName]
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

// ==================== GATEWAY: OAUTH ON THE MCP WEB APP ====================

/*
  Entra app registration guarding the private MCP web app. Federated to the MCP web app's
  user-assigned managed identity (MI-as-FIC) so App Service built-in auth is secretless.
*/
module mcpAppRegistration 'modules/gateway/app-registration.bicep' = {
  name: 'mcp-appreg-${uniqueSuffix}-deployment'
  params: {
    clientAppName: 'mcp-gateway-${uniqueSuffix}'
    clientAppDisplayName: 'MCP Gateway (${uniqueSuffix})'
    webAppIdentityPrincipalId: aiDependencies.outputs.mcpWebAppIdentityPrincipalId
  }
}

/*
  App Service built-in auth (EasyAuth) on the MCP web app — returns 401 on unauthenticated
  requests (machine-to-machine, no interactive redirect) and validates the AgenticIdentityToken
  audience against the app registration's Application ID URI.
*/
module mcpBuiltinAuth 'modules/gateway/builtin-auth.bicep' = {
  name: 'mcp-auth-${uniqueSuffix}-deployment'
  params: {
    appServiceName: aiDependencies.outputs.mcpWebAppName
    clientId: mcpAppRegistration.outputs.clientAppId
    issuer: mcpAppRegistration.outputs.issuer
    allowedAudience: mcpAppRegistration.outputs.audience
  }
}

// ==================== AI PROJECT ====================

/*
  Creates a new project (sub-resource of the AI Services account)
*/
module aiProject 'modules/foundry/ai-project-identity.bicep' = {
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
    mcpUrl: '${apimMcpApi.outputs.mcpGatewayUrl}/'
    // Mint the agent's tool token for our own app registration (an audience we control), so
    // App Service built-in auth on the MCP web app accepts it.
    mcpAudience: mcpAppRegistration.outputs.audience

  }
  dependsOn: [
    privateEndpointAndDNS
    cosmosDB
    aiSearch
    storage
  ]
}

module formatProjectWorkspaceId 'modules/foundry/format-project-workspace-id.bicep' = {
  name: 'format-project-workspace-id-${uniqueSuffix}-deployment'
  params: {
    projectWorkspaceId: aiProject.outputs.projectWorkspaceId
  }
}

/*
  Assigns the project SMI the storage blob data contributor role on the storage account
*/
module storageAccountRoleAssignment 'modules/rbac/azure-storage-account-role-assignment.bicep' = {
  name: 'storage-ra-${uniqueSuffix}-deployment'
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
module appInsightsRoleAssignment 'modules/rbac/app-insights-role-assignment.bicep' = {
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
module acrRoleAssignment 'modules/rbac/acr-role-assignment.bicep' = {
  name: 'acr-ra-${uniqueSuffix}-deployment'
  params: {
    acrName: acr.outputs.acrName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
}

/*
  Assigns Foundry User role to the project SMI on the Foundry project resource.
*/
module foundryProjectRoleAssignment 'modules/rbac/foundry-project-role-assignment.bicep' = {
  name: 'foundry-project-ra-${uniqueSuffix}-deployment'
  params: {
    accountName: aiAccount.outputs.accountName
    projectName: aiProject.outputs.projectName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
}

// The Comos DB Operator role must be assigned before the caphost is created
module cosmosAccountRoleAssignments 'modules/rbac/cosmosdb-account-role-assignment.bicep' = {
  name: 'cosmos-account-ra-${uniqueSuffix}-deployment'
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
module aiSearchRoleAssignments 'modules/rbac/ai-search-role-assignments.bicep' = {
  name: 'ai-search-ra-${uniqueSuffix}-deployment'
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
module addProjectCapabilityHost 'modules/foundry/add-project-capability-host.bicep' = {
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
module storageContainersRoleAssignment 'modules/rbac/blob-storage-container-role-assignments.bicep' = {
  name: 'storage-containers-ra-${uniqueSuffix}-deployment'
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
module cosmosContainerRoleAssignments 'modules/rbac/cosmos-container-role-assignments.bicep' = {
  name: 'cosmos-container-ra-${uniqueSuffix}-deployment'
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

// ==================== VMs + BASTION (in Foundry Spoke) ====================

// Two boxes, one job each:
//   * linuxVmModule   - ALWAYS deployed. The in-VNet workhorse: the `az vm run-command`
//                       target for agent seeding AND the self-hosted Actions runner host.
//                       Linux because microsoft/ai-agent-evals is effectively Linux-only.
//                       Holds all the private-plane RBAC (Foundry / KV / Contributor).
//   * vmModule        - OPTIONAL Windows dev VM, human RDP + Edge inspection only, no RBAC.
// Bastion is its own module, gated by deployBastion (which defaults to deployWindowsVm):
// it exists purely for interactive human access, and the Linux VM needs no interactive
// path for automation. Deploying it separately means you CAN still opt into Bastion SSH
// on the Linux VM without paying for the Windows VM.

module linuxVmModule 'modules/resources/vm-linux.bicep' = {
  name: 'linux-vm-deployment-${uniqueSuffix}'
  params: {
    location: location
    vmName: 'runner-vm-${uniqueSuffix}'
    virtualNetworkName: foundrySpokeVnet.outputs.virtualNetworkName
    subnetName: foundrySpokeVnet.outputs.vmSubnetName
    adminPassword: vmAdminPassword
    adminUsername: vmAdminUsername
  }
  dependsOn: [
    privateEndpointAndDNS
  ]
}

module vmModule 'modules/resources/vm.bicep' = if (deployWindowsVm) {
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

module bastionModule 'modules/resources/bastion.bicep' = if (deployBastion) {
  name: 'bastion-deployment-${uniqueSuffix}'
  params: {
    location: location
    virtualNetworkName: foundrySpokeVnet.outputs.virtualNetworkName
  }
  dependsOn: [
    privateEndpointAndDNS
  ]
}


// ==================== MODEL GATEWAY (spoke) ====================

/*
  Enterprise model gateway (always deployed). In a NEW spoke (10.3.0.0/16) peered
  only to the hub this deploys:
    - an APIM Standard v2 instance (inbound PE + outbound VNet integration),
    - a locked-down "provider" AI Foundry that actually hosts the model,
  then advertises APIM to the primary Foundry project as an ApiManagement
  connection (ProjectManagedIdentity / keyless). A second agent is seeded that
  uses the '<connection>/<model>' reference. The agent reaches APIM's inbound PE
  by force-tunnelling through the Azure Firewall (no spoke-to-spoke peering).
*/

// Step 7: model-gateway spoke VNet.
// ALWAYS deployed: APIM (which lives in this spoke) is now shared by the optional
// model gateway AND the optional Teams/M365 publish inbound path.
module modelGatewaySpokeVnet 'modules/model-gateway/model-gateway-spoke-vnet.bicep' = {
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
module hubToModelGatewayPeering 'modules/network/vnet-peering.bicep' = {
  name: 'hub-model-gateway-peering-${uniqueSuffix}'
  params: {
    hubVnetName: hubNetwork.outputs.hubVnetName
    spokeVnetName: modelGatewaySpokeVnet.outputs.virtualNetworkName
    hubVnetId: hubNetwork.outputs.hubVnetId
    spokeVnetId: modelGatewaySpokeVnet.outputs.virtualNetworkId
  }
}

// Provider AI Foundry (the "real" model provider) — minimal, locked-down.
module providerFoundry 'modules/model-gateway/provider-foundry.bicep' = {
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

// APIM Standard v2 in the gateway spoke. ALWAYS deployed (shared gateway).
module apim 'modules/model-gateway/apim.bicep' = {
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

// APIM inbound private endpoint + privatelink.azure-api.net DNS. ALWAYS deployed:
// callers (model-gateway connection AND the Teams inbound YARP path) reach APIM only
// through this PE once apim-lockdown flips publicNetworkAccess to 'Disabled'.
module apimPrivateEndpoint 'modules/model-gateway/apim-private-endpoint.bicep' = {
  name: 'apim-pe-${uniqueSuffix}-deployment'
  params: {
    location: location
    suffix: uniqueSuffix
    apimId: apim.outputs.apimId
    apimName: apim.outputs.apimName
    peSubnetId: modelGatewaySpokeVnet.outputs.peSubnetId
    hubVnetId: hubNetwork.outputs.hubVnetId
  }
}

// Provider Foundry private endpoint + DNS in the gateway spoke (model gateway only).
module modelGatewayPrivateEndpoints 'modules/model-gateway/model-gateway-private-endpoints.bicep' = {
  name: 'model-gateway-pe-${uniqueSuffix}-deployment'
  params: {
    location: location
    providerAccountId: providerFoundry.outputs.accountId
    providerAccountName: providerFoundry.outputs.accountName
    peSubnetId: modelGatewaySpokeVnet.outputs.peSubnetId
  }
  dependsOn: [
    privateEndpointAndDNS
  ]
}

// Grant APIM MI Cognitive Services User on the provider Foundry (backend MI auth).
module apimProviderRoleAssignment 'modules/model-gateway/apim-provider-role-assignment.bicep' = {
  name: 'model-gateway-apim-rbac-${uniqueSuffix}-deployment'
  params: {
    providerAccountName: providerFoundry.outputs.accountName
    apimPrincipalId: apim.outputs.apimPrincipalId
  }
}

// APIM MCP server API — exposes the private MCP web app through the APIM gateway.
// The Foundry MCP connection points at this APIM endpoint instead of directly at the
// App Service private endpoint, so all MCP tool traffic flows through the gateway.
module apimMcpApi 'modules/model-gateway/apim-mcp-api.bicep' = {
  name: 'mcp-apim-api-${uniqueSuffix}-deployment'
  params: {
    apimName: apim.outputs.apimName
    mcpWebAppFqdn: aiDependencies.outputs.mcpWebAppFqdn
  }
  dependsOn: [
    apimProviderRoleAssignment
  ]
}

// APIM inference API + policy (inbound token validation, backend + MI auth).
module apimApiPolicy 'modules/model-gateway/apim-api-policy.bicep' = {
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
module apimConnection 'modules/model-gateway/apim-connection.bicep' = {
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

// APIM Teams / M365 inbound API + policy (validate Bot Framework JWT, forward to the
// agent activityProtocol endpoint on the primary Foundry PE). Teams path only.
module apimTeamsApi 'modules/model-gateway/apim-teams-api.bicep' = if (enableTeamsPublish) {
  name: 'teams-apim-api-${uniqueSuffix}-deployment'
  params: {
    apimName: apim.outputs.apimName
    foundryAccountName: aiAccount.outputs.accountName
    projectName: aiProject.outputs.projectName
    botAppIds: teamsBotAppIds
    expectedTenantId: tenant().tenantId
  }
}

// Phase 2 lockdown: flip APIM publicNetworkAccess to 'Disabled' now that the inbound
// private endpoint exists (APIM forbids 'Disabled' at create time). Runs after the PE
// and after the API/policy children so it never races their creation.
module apimLockdown 'modules/model-gateway/apim-lockdown.bicep' = {
  name: 'model-gateway-apim-lockdown-${uniqueSuffix}-deployment'
  params: {
    apimName: apim.outputs.apimName
    location: location
    apimOutboundSubnetId: modelGatewaySpokeVnet.outputs.apimSubnetId
  }
  dependsOn: [
    apimPrivateEndpoint
    apimApiPolicy
    apimTeamsApi
    apimMcpApi
  ]
}

// Gateway firewall rules (ALWAYS on — APIM is always-on): APIM platform egress, plus the
// model-gateway (agent -> APIM PE) and Teams (APIM -> Foundry PE) cross-spoke allows.
// Deliberately sequenced AFTER the APIM deployment: APIM Standard v2 takes ~15-45 min to
// provision, which leaves the firewall long-idle after firewall.bicep's defaultRuleGroup
// PUT before this second rule-collection-group PUT lands on the same policy. This avoids
// the transient "faulted referenced firewalls" fault Basic-tier firewalls hit when two
// rule-collection-group PUTs arrive back-to-back.
module gatewayFirewallRules 'modules/model-gateway/gateway-firewall-rules.bicep' = {
  name: 'gateway-fwall-rules-${uniqueSuffix}-deployment'
  params: {
    firewallPolicyName: firewallPolicyName
    agentSubnetCidr: agentSubnetCidr
    modelGatewayPeSubnetCidr: modelGatewayPeSubnetCidr
    modelGatewayApimSubnetCidr: modelGatewayApimSubnetCidr
    foundryPeSubnetCidr: foundryPeSubnetCidr
    appServicePeSubnetCidr: appServicePeSubnetCidr
  }
  dependsOn: [
    firewall
    apim
  ]
}

// ==================== SEED AGENTS: VM RBAC ====================

// Agent seeding runs from the azd `predeploy` hook (hooks/predeploy.ps1), which uses
// `az vm run-command` to execute scripts/seed-agents.ps1 on the private LINUX VM (the
// only host that can reach the Foundry private endpoint — the Windows dev VM is optional
// and intentionally has no such access). The Linux VM's system-assigned identity needs
// Foundry User on the project so the on-VM script can acquire a token and call the
// Agents API — that RBAC is provisioned here.
module vmFoundryRole 'modules/rbac/vm-foundry-role.bicep' = {
  name: 'vm-foundry-role-${uniqueSuffix}'
  params: {
    accountName: aiAccount.outputs.accountName
    projectName: aiProject.outputs.projectName
    vmPrincipalId: linuxVmModule.outputs.vmPrincipalId
  }
  dependsOn: [
    addProjectCapabilityHost
  ]
}

// ==================== SELF-HOSTED GITHUB ACTIONS RUNNER (opt-in) ====================

// When githubRunnerRepoUrl is set, install a self-hosted runner on the Linux worker VM so
// complex, representative deployments can run INSIDE the VNet (reaching the private
// Foundry endpoint directly) instead of being marshalled through `az vm run-command`.
// The VM MI needs Key Vault Secrets User to read the runner PAT; the Run Command that
// runs the bootstrap is sequenced AFTER that role assignment. See docs/github-runner.md.
var installGithubRunner = !empty(githubRunnerRepoUrl)

module vmKeyVaultSecretsRole 'modules/rbac/vm-keyvault-secrets-role.bicep' = if (installGithubRunner) {
  name: 'vm-kv-secrets-role-${uniqueSuffix}'
  params: {
    keyVaultName: keyVault.outputs.keyVaultName
    vmPrincipalId: linuxVmModule.outputs.vmPrincipalId
  }
}

// Grant the VM MI Contributor over the resource group so the runner (which runs AS the
// VM MI) can do control-plane work for representative end-to-end deployments — e.g.
// create the Azure Bot Service in the gated Teams / M365 publish workflow. Opt-in
// (runner only) and scoped to the resource group to bound the blast radius.
module vmContributorRole 'modules/rbac/vm-contributor-role.bicep' = if (installGithubRunner) {
  name: 'vm-contributor-role-${uniqueSuffix}'
  params: {
    vmPrincipalId: linuxVmModule.outputs.vmPrincipalId
  }
}

// Grant the VM MI Cognitive Services OpenAI User on the AI Services account so the nightly
// eval workflow's AI-assisted evaluators can call the judge model's inference API. This is a
// data-plane action neither Contributor (management-plane) nor Foundry User (Agents API)
// covers — without it the judge calls fail with 401 PermissionDenied. See the module header
// for the full rationale. Opt-in (runner only) and scoped to the account.
module vmOpenAiUserRole 'modules/rbac/vm-openai-user-role.bicep' = if (installGithubRunner) {
  name: 'vm-openai-user-role-${uniqueSuffix}'
  params: {
    accountName: aiAccount.outputs.accountName
    vmPrincipalId: linuxVmModule.outputs.vmPrincipalId
  }
}

// Write the PAT into Key Vault via ARM (control plane) — only when a value is
// supplied. Skipped (leaving any existing secret intact) when GITHUB_RUNNER_PAT
// is empty, so the secret can be seeded once and the env var cleared afterward.
module runnerPatSecret 'modules/resources/runner-pat-secret.bicep' = if (installGithubRunner && !empty(githubRunnerPat)) {
  name: 'runner-pat-secret-${uniqueSuffix}'
  params: {
    keyVaultName: keyVault.outputs.keyVaultName
    secretName: githubRunnerPatSecretName
    patValue: githubRunnerPat
  }
}

module vmRunnerExtension 'modules/resources/vm-runner-extension.bicep' = if (installGithubRunner) {
  name: 'vm-runner-extension-${uniqueSuffix}'
  params: {
    vmName: linuxVmModule.outputs.vmName
    location: location
    githubRunnerRepoUrl: githubRunnerRepoUrl
    keyVaultName: keyVault.outputs.keyVaultName
    githubRunnerPatSecretName: githubRunnerPatSecretName
    githubRunnerLabels: githubRunnerLabels
    runnerUser: vmAdminUsername
  }
  dependsOn: [
    vmKeyVaultSecretsRole
    runnerPatSecret
  ]
}


// ==================== OUTPUTS (consumed by the azd predeploy hook) ====================

@description('Resource group the deployment targets.')
output AZURE_RESOURCE_GROUP string = resourceGroup().name

@description('Name of the private Linux VM the seed-agents hook runs its script on.')
output SEED_AGENTS_VM_NAME string = linuxVmModule.outputs.vmName


@description('Foundry project endpoint the seeded agents are created against.')
output AZURE_AI_PROJECT_ENDPOINT string = aiProject.outputs.projectEndpoint

@description('Foundry (Cognitive Services) account name. Used by the predown hook to delete capability hosts before teardown.')
output AZURE_AI_ACCOUNT_NAME string = aiAccount.outputs.accountName

@description('Foundry project name. Used by the predown hook to delete capability hosts before teardown.')
output AZURE_AI_PROJECT_NAME string = aiProject.outputs.projectName

@description('Model deployment name assigned to the default seeded agent.')
output AZURE_AI_MODEL_DEPLOYMENT_NAME string = modelName

@description('Whether to seed the second (model-gateway) agent. Always true — the model gateway is always deployed.')
output SEED_ENABLE_SECOND_AGENT bool = true

@description('Model reference for the second (model-gateway) agent.')
output SEED_SECOND_AGENT_MODEL string = apimConnection.outputs.agentModelReference

// ---- Teams / M365 publish (consumed by the postdeploy hook) ----

@description('Whether the Teams / M365 publish path was deployed (gates the postdeploy hook).')
output SEED_ENABLE_TEAMS_PUBLISH bool = enableTeamsPublish

@description('Comma-separated names of the seeded agents to publish to Teams / M365 (the postdeploy hook creates one bot per agent, endpoint /teams/<agentName>).')
output TEAMS_PUBLISH_AGENT_NAMES string = join(teamsPublishAgentNames, ',')

@description('Public FQDN of the YARP proxy — the Azure Bot Service messaging endpoint host.')
output TEAMS_YARP_FQDN string = aiDependencies.outputs.yarpWebAppFqdn

@description('APIM instance name (hook pins the Teams API validate-jwt audience live once the bot App ID is known).')
output TEAMS_APIM_NAME string = apimName

@description('Name of the APIM Teams inbound API (== its path).')
output TEAMS_APIM_API_NAME string = apimTeamsApi.?outputs.apiName ?? 'teams'

@description('Entra tenant the single-tenant bot registration lives in.')
output TEAMS_TENANT_ID string = tenant().tenantId

@description('Suggested Azure Bot Service resource name the postdeploy hook creates (stable per environment).')
output TEAMS_BOT_NAME string = 'bot-${uniqueSuffix}'

@description('Environment unique suffix, prefixed onto each published agent display name so entries are unambiguous per deployment in a shared tenant catalog (e.g. "<suffix>-teams-agent").')
output TEAMS_NAME_PREFIX string = uniqueSuffix

@description('Log Analytics workspace resource ID — the postdeploy hook passes it to bot-service.bicep so the Bot Service diagnostic setting is codified (BotRequest logs -> workspace).')
output TEAMS_LOG_ANALYTICS_ID string = lanalytics.id
