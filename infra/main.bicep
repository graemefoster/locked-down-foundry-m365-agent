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

// RAI guardrail policy parameters
@description('Assign the built-in "Guardrail for Cognitive Services Deployments" initiative (Audit) at this resource group. Audit-only: reports compliance, does not block.')
param enableRaiGuardrailPolicy bool = true
@description('Deploy a deliberately NON-COMPLIANT model (weak custom RAI policy) to demonstrate the guardrail flagging it. Off by default.')
param enableNonCompliantModelDemo bool = false

@description('''
Deploy the STANDARD agent tier: bring-your-own agent state stores (CosmosDB threads, Storage
files, AI Search vectors) wired to the project via an Agents capability host on the PROJECT.
Set to false for the BASIC agent tier — no Cosmos/Storage/Search at all; the account-scope
capability host runs the Agents service on Microsoft-managed stores. Basic is a much faster,
still-locked-down demo (drops the whole BYO data plane + its private endpoints). The
account-scope capability host is deployed in BOTH tiers. NO DEFAULT — azd always prompts so the
agent tier is an explicit, conscious choice. See docs/NETWORKING.md.
''')
param deployStandardAgent bool

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

@description('Optional caller app/client ID to pin in the APIM validate-azure-ad-token policy (empty = validate tenant + audience only). See docs/NETWORKING.md.')
param gatewayCallerAppId string = ''

@description('Optional audience the caller Entra token must carry for the governed foundry-agents /responses API (e.g. api://<clientId>). Empty = validate tenant + signature only.')
param agentCallerAudience string = ''

@description('Optional provisioning-operator public IP (bare IPv4 or CIDR) to allow into the PUBLIC YARP edge for dev/test, in addition to the Microsoft Teams inbound ranges. Empty (default) = Teams-only. Set opt-in via DEPLOYER_PUBLIC_IP (preprovision hook). Network layer only — callers still need a valid Entra token + token-limit allowlist entry.')
param deployerPublicIp string = ''

@description('Object (principal) ID of the deployment operator, granted "Azure API Center Data Reader" on the API Center so they can read/search the synced inventory. azd populates this from AZURE_PRINCIPAL_ID. Empty = skip the grant.')
param deployerPrincipalId string = ''

@description('Principal type of the deployment operator, used on its role assignment. Interactive azd runs are Users; CI/service-principal runs are ServicePrincipals.')
@allowed([
  'User'
  'ServicePrincipal'
  'Group'
])
param deployerPrincipalType string = 'User'

// ==================== TEAMS / M365 PUBLISH ====================
// The Teams / M365 Copilot inbound publish path is ALWAYS deployed: an APIM API that forwards
// to the agent activityProtocol endpoint, plus the YARP proxy flipped public (IP-restricted to
// the Bot Channel Adapter ranges). The Azure Bot Service + Step 3/4 publish are performed by
// the in-VNet Teams-publish workflow path (scripts/publish-teams-runner.ps1 -> publish-teams.ps1),
// one agent per run. The single path-routed APIM Teams API listens on /teams/{agentName}, so it
// does not need to know the agent names ahead of time.
@description('DEV bot Microsoft App IDs (= each published dev-project agent identity principal_id) allowed as the DEV APIM Teams API validate-jwt audiences. Empty = validate the Bot Framework issuer only; the Teams-publish pipeline rebuilds the full dev audience allowlist live once the dev agents are deployed.')
param teamsBotAppIdsDev array = []

@description('TEST bot Microsoft App IDs allowed as the TEST APIM Teams API validate-jwt audiences. Empty = validate the Bot Framework issuer only; the Teams-publish pipeline rebuilds the full test audience allowlist live once the test agents are deployed.')
param teamsBotAppIdsTest array = []

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
worker VM, so this defaults to FALSE — you only pay the Windows licence, compute
and Bastion cost when you explicitly opt in with
`azd env set DEPLOY_WINDOWS_VM true`.
''')
param deployWindowsVm bool = false

@description('''
Deploy Azure Bastion. Bastion exists for INTERACTIVE human access: it is the only way
to reach the Windows dev VM (RDP), so this DEFAULTS to deployWindowsVm — turn the
Windows VM off and Bastion goes with it. The Linux worker VM needs no interactive
path (agent seeding runs on the self-hosted Actions runner, which registers outbound),
so a CI-only environment gets neither. Deliberately NOT in main.parameters.json so the
derived default applies; pass deployBastion explicitly only for direct Bicep deployments
that need Bastion SSH into the Linux VM without the Windows VM.
''')
param deployBastion bool = deployWindowsVm

@description('''
GitHub repo URL (https://github.com/owner/repo) to register a self-hosted Actions
runner on the Linux worker VM against. Leave EMPTY (default) to skip runner
installation. When set, you MUST also supply githubRunnerPat — without a PAT there
is no secret to seed and the runner is skipped (not installed). When both are set,
the VM installs a runner as a systemd service, reading the fine-grained PAT from Key
Vault via its managed identity. See docs/github-runner.md.
''')
param githubRunnerRepoUrl string = ''


@description('Name of the Key Vault secret holding the runner PAT (Administration: read & write). Seeded manually.')
param githubRunnerPatSecretName string = 'gh-runner-pat'

@description('''
Fine-grained GitHub PAT (Administration: read & write) for the self-hosted runner.
REQUIRED to install the runner (together with githubRunnerRepoUrl) — the runner is
skipped if either is empty. Written into Key Vault by Bicep (control-plane write,
works despite the private KV firewall). Sourced from ${GITHUB_RUNNER_PAT} (empty by
default). Set it with `azd env set GITHUB_RUNNER_PAT <pat>`. You may clear it after
the runner is installed — the systemd service and KV secret persist — but a later
`azd provision` will then skip the runner modules (it won't re-register the runner).
''')
@secure()
param githubRunnerPat string = ''

@description('Comma-separated labels applied to the self-hosted runner.')
param githubRunnerLabels string = 'vnet,foundry-private'

var projectNameDev = toLower('${firstProjectName}-dev-${uniqueSuffix}')
var projectNameTest = toLower('${firstProjectName}-test-${uniqueSuffix}')
var cosmosDBName = toLower('${aiServices}${uniqueSuffix}cosmosdb')
var aiSearchName = toLower('${aiServices}${uniqueSuffix}search')
var azureStorageName = toLower('${aiServices}${uniqueSuffix}stg')
var keyVaultName = toLower('${aiServices}${uniqueSuffix}kv')

@description('Base name for the per-project capability hosts (suffixed with dev/test).')
param projectCapHost string = 'caphostproj'

var projectCapHostDev = '${projectCapHost}dev'
var projectCapHostTest = '${projectCapHost}test'

var appServicePlanName = toLower('${uniqueSuffix}-asp')

var logAnalyticsName = toLower('${uniqueSuffix}-la')
var appInsightsName = toLower('${uniqueSuffix}-appi')
var acrName = toLower('${uniqueSuffix}acr')

// ==================== ADDRESSING & NAMING (shared scheme) ====================
// The deterministic firewall-policy name + subnet CIDR scheme. Kept on main (the single
// source of truth) and threaded to stage 00 (network build) and stage 30 (gateway firewall
// rules) as params, so neither stage recomputes — and there is no spoke<->firewall cycle.
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

// Model-gateway spoke (always deployed). CIDRs are deterministic so they can be passed to
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

// ==================== STAGE 00 — FOUNDATION ====================
// The substrate (zero dependencies): networking (hub + 3 spokes, firewall, DNS resolver,
// peerings, flow logs) + observability sink (Log Analytics + App Insights).
module stage00 'stages/00-foundation/00-foundation.bicep' = {
  name: 'stage00-foundation-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    vnetName: vnetName
    agentSubnetName: agentSubnetName
    peSubnetName: peSubnetName
    logAnalyticsName: logAnalyticsName
    appInsightsName: appInsightsName
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
  }
}

// ==================== STAGE 10 — PLATFORM ====================
// The data substrate + shared gateway on the stage 00 foundation: Key Vault (CMK) +
// dependent resources (Storage/Cosmos/Search/App Service) + ACR, their private endpoints
// & DNS, the model gateway (provider Foundry + APIM + the MCP gateway wiring), the
// Storage CMK re-PUT. The Foundry account (stage 13) + AI project (stage 15) sit on top.

// Storage SKU — no-ZRS regions fall back to GRS. Computed in main because stage 00
// (flow-logs storage) consumes it too; also threaded into stage 10 (storage CMK re-PUT).
var noZRSRegions = ['southindia', 'westus', 'northcentralus']
var storageSkuName = contains(noZRSRegions, location) ? 'Standard_GRS' : 'Standard_ZRS'

module stage10 'stages/10-platform/10-platform.bicep' = {
  name: 'stage10-platform-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    appServicePlanName: appServicePlanName
    keyVaultName: keyVaultName
    azureStorageName: azureStorageName
    aiSearchName: aiSearchName
    cosmosDBName: cosmosDBName
    acrName: acrName
    appInsightsName: appInsightsName
    apimGatewayUrl: apimGatewayUrl
    deployerPublicIp: deployerPublicIp
    deployStandardAgent: deployStandardAgent
    storageSkuName: storageSkuName
    providerAccountName: providerAccountName
    apimName: apimName
    gatewayModelName: gatewayModelName
    gatewayModelFormat: gatewayModelFormat
    gatewayModelVersion: gatewayModelVersion
    gatewayModelSkuName: gatewayModelSkuName
    gatewayModelCapacity: gatewayModelCapacity
    logAnalyticsId: stage00.outputs.logAnalyticsId
    appInsightsConnectionString: stage00.outputs.appInsightsConnectionString
    appInsightsId: stage00.outputs.appInsightsId
    appServiceDelegatedSubnetId: stage00.outputs.appServiceDelegatedSubnetId
    hubVnetId: stage00.outputs.hubVnetId
    foundrySpokeVnetName: stage00.outputs.foundrySpokeVnetName
    foundryPeSubnetName: stage00.outputs.foundryPeSubnetName
    modelGatewayApimSubnetId: stage00.outputs.modelGatewayApimSubnetId
    modelGatewayPeSubnetId: stage00.outputs.modelGatewayPeSubnetId
    aiSearchDnsZoneId: stage00.outputs.aiSearchDnsZoneId
    storageDnsZoneId: stage00.outputs.storageDnsZoneId
    cosmosDBDnsZoneId: stage00.outputs.cosmosDBDnsZoneId
    acrDnsZoneId: stage00.outputs.acrDnsZoneId
    keyVaultDnsZoneId: stage00.outputs.keyVaultDnsZoneId
  }
}

// ==================== STAGE 11 — API CENTER ====================
// A free-plan Azure API Center that continuously syncs the stage-10 APIM APIs (incl. the
// MCP servers) into a discoverable inventory. Runs AFTER stage 10 — the APIM instance must
// exist first (apimName is threaded from stage 10's output to order this stage).
module stage11 'stages/11-api-center/11-api-center.bicep' = {
  name: 'stage11-api-center-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    apimName: stage10.outputs.apimName
    deployerPrincipalId: deployerPrincipalId
    deployerPrincipalType: deployerPrincipalType
  }
}

// ==================== STAGE 13 — FOUNDRY ACCOUNT ====================
// The centrepiece: the Foundry (AI Services) account + model, and EVERYTHING that stands it
// up and protects it — its private endpoint + DNS, its Key Vault Crypto / App Insights RBAC,
// and the CMK re-PUT of the account. Needs the Key Vault + DNS zones + data substrate (10).
module stage13 'stages/13-foundry/13-foundry.bicep' = {
  name: 'stage13-foundry-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    accountName: accountName
    modelName: modelName
    modelFormat: modelFormat
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity
    appInsightsName: appInsightsName
    agentSubnetId: stage00.outputs.agentSubnetId
    logAnalyticsId: stage00.outputs.logAnalyticsId
    appInsightsConnectionString: stage00.outputs.appInsightsConnectionString
    appInsightsId: stage00.outputs.appInsightsId
    foundrySpokeVnetName: stage00.outputs.foundrySpokeVnetName
    foundryPeSubnetName: stage00.outputs.foundryPeSubnetName
    aiServicesDnsZoneId: stage00.outputs.aiServicesDnsZoneId
    openAiDnsZoneId: stage00.outputs.openAiDnsZoneId
    cognitiveServicesDnsZoneId: stage00.outputs.cognitiveServicesDnsZoneId
    keyVaultName: stage10.outputs.keyVaultName
    keyVaultUri: stage10.outputs.keyVaultUri
    keyName: stage10.outputs.keyName
    keyUriWithVersion: stage10.outputs.keyUriWithVersion
  }
}

// ==================== STAGE 15 — FOUNDRY PROJECT ====================
// The AI project (sub-resource of the account) + all of its data-plane RBAC, its Key Vault
// Crypto grant, and the Agents capability host. Needs the account (13) + data substrate +
// private endpoints (10).
module stage15dev 'stages/15-foundry-project/15-foundry-project.bicep' = {
  name: 'stage15-foundry-project-dev-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    projectName: projectNameDev
    projectDescription: projectDescription
    displayName: displayName
    projectCapHost: projectCapHostDev
    deployStandardAgent: deployStandardAgent
    accountName: stage13.outputs.aiAccountName
    aiSearchName: stage10.outputs.aiSearchName
    aiSearchServiceResourceGroupName: stage10.outputs.aiSearchServiceResourceGroupName
    aiSearchServiceSubscriptionId: stage10.outputs.aiSearchServiceSubscriptionId
    cosmosDBName: stage10.outputs.cosmosDBName
    cosmosDBSubscriptionId: stage10.outputs.cosmosDBSubscriptionId
    cosmosDBResourceGroupName: stage10.outputs.cosmosDBResourceGroupName
    azureStorageName: stage10.outputs.azureStorageName
    azureStorageSubscriptionId: stage10.outputs.azureStorageSubscriptionId
    azureStorageResourceGroupName: stage10.outputs.azureStorageResourceGroupName
    acrName: stage10.outputs.acrName
    appInsightsName: appInsightsName
    keyVaultName: stage10.outputs.keyVaultName
    logAnalyticsId: stage00.outputs.logAnalyticsId
  }
}

// The TEST project shares the same account + BYO Cosmos/Storage/Search connections. Sequence it
// AFTER the dev project: both write container-scope (workspace-id-scoped) RBAC on the shared
// stores, so serialising them avoids the known back-to-back RBAC/rule-collection PUT faults.
module stage15test 'stages/15-foundry-project/15-foundry-project.bicep' = {
  name: 'stage15-foundry-project-test-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    projectName: projectNameTest
    projectDescription: projectDescription
    displayName: displayName
    projectCapHost: projectCapHostTest
    deployStandardAgent: deployStandardAgent
    accountName: stage13.outputs.aiAccountName
    aiSearchName: stage10.outputs.aiSearchName
    aiSearchServiceResourceGroupName: stage10.outputs.aiSearchServiceResourceGroupName
    aiSearchServiceSubscriptionId: stage10.outputs.aiSearchServiceSubscriptionId
    cosmosDBName: stage10.outputs.cosmosDBName
    cosmosDBSubscriptionId: stage10.outputs.cosmosDBSubscriptionId
    cosmosDBResourceGroupName: stage10.outputs.cosmosDBResourceGroupName
    azureStorageName: stage10.outputs.azureStorageName
    azureStorageSubscriptionId: stage10.outputs.azureStorageSubscriptionId
    azureStorageResourceGroupName: stage10.outputs.azureStorageResourceGroupName
    acrName: stage10.outputs.acrName
    appInsightsName: appInsightsName
    keyVaultName: stage10.outputs.keyVaultName
    logAnalyticsId: stage00.outputs.logAnalyticsId
  }
  dependsOn: [
    stage15dev
  ]
}

// ==================== STAGE 20 — WORKLOAD: MCP ====================
// The governed MCP workload on top of the stage 10 platform: the private MCP web app
// + its MI-as-FIC identity + private endpoint, the guarding Entra app registration, the
// APIM MCP server API(s) fronting it, and App Service built-in auth on the web app.
module stage20dev 'stages/20-workload-mcp/20-workload-mcp.bicep' = {
  name: 'stage20-workload-mcp-dev-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    env: 'dev'
    appServicePlanName: appServicePlanName
    appInsightsName: appInsightsName
    appServiceDelegatedSubnetId: stage00.outputs.appServiceDelegatedSubnetId
    logAnalyticsId: stage00.outputs.logAnalyticsId
    appServiceSpokeVnetName: stage00.outputs.appServiceSpokeVnetName
    appServicePeSubnetName: stage00.outputs.appServicePeSubnetName
    appServiceDnsZoneId: stage00.outputs.appServiceDnsZoneId
    apimName: stage10.outputs.apimName
  }
}

module stage20test 'stages/20-workload-mcp/20-workload-mcp.bicep' = {
  name: 'stage20-workload-mcp-test-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    env: 'test'
    appServicePlanName: appServicePlanName
    appInsightsName: appInsightsName
    appServiceDelegatedSubnetId: stage00.outputs.appServiceDelegatedSubnetId
    logAnalyticsId: stage00.outputs.logAnalyticsId
    appServiceSpokeVnetName: stage00.outputs.appServiceSpokeVnetName
    appServicePeSubnetName: stage00.outputs.appServicePeSubnetName
    appServiceDnsZoneId: stage00.outputs.appServiceDnsZoneId
    apimName: stage10.outputs.apimName
  }
  dependsOn: [
    stage20dev
  ]
}

// URL of the DEV sample MCP server (the first configured server) that the reusable deploy-agent
// workflow injects as a dev agent's `server_url`. first() is safe: mcp/mcp.json always has >=1
// server, and the sample 'mcp' server is the first entry by convention.
var mcpSampleGatewayUrl = '${first(stage20dev.outputs.servers).url}/'
var mcpSampleGatewayUrlTest = '${first(stage20test.outputs.servers).url}/'

// ==================== STAGE 30 — GOVERNANCE ====================
// Post-platform governance: project MCP connections, APIM API/policy/connection + Teams API,
// RAI guardrail (+ non-compliant demo), APIM lockdown (STRICTLY LAST), and cross-spoke gateway
// firewall rules. Depends only downward on stages 00/10/20 (their outputs are threaded in).
module stage30 'stages/30-governance/30-governance.bicep' = {
  name: 'stage30-governance-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    aiAccountName: stage13.outputs.aiAccountName
    projectNameDev: stage15dev.outputs.projectName
    projectNameTest: stage15test.outputs.projectName
    apimName: stage10.outputs.apimName
    providerAccountId: stage10.outputs.providerAccountId
    projectIdDev: stage15dev.outputs.projectId
    gatewayUrl: stage10.outputs.gatewayUrl
    serversDev: stage20dev.outputs.servers
    serversTest: stage20test.outputs.servers
    mcpAudienceDev: stage20dev.outputs.mcpAudience
    mcpAudienceTest: stage20test.outputs.mcpAudience
    modelGatewayApimSubnetId: stage00.outputs.modelGatewayApimSubnetId
    providerBackendBaseUrl: providerBackendBaseUrl
    gatewayCallerAppId: gatewayCallerAppId
    modelGatewayConnectionName: modelGatewayConnectionName
    gatewayModelName: gatewayModelName
    firewallPolicyName: firewallPolicyName
    agentSubnetCidr: agentSubnetCidr
    modelGatewayPeSubnetCidr: modelGatewayPeSubnetCidr
    modelGatewayApimSubnetCidr: modelGatewayApimSubnetCidr
    foundryPeSubnetCidr: foundryPeSubnetCidr
    appServicePeSubnetCidr: appServicePeSubnetCidr
    teamsBotAppIdsDev: teamsBotAppIdsDev
    teamsBotAppIdsTest: teamsBotAppIdsTest
    enableRaiGuardrailPolicy: enableRaiGuardrailPolicy
    enableNonCompliantModelDemo: enableNonCompliantModelDemo
    modelName: modelName
    modelFormat: modelFormat
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    agentCallerAudience: agentCallerAudience
  }
  dependsOn: [
    stage00
    stage10
    stage13
    stage15dev
    stage15test
    stage20dev
    stage20test
  ]
}


// ==================== STAGE 40 — RUNNER ====================
// In-VNet compute: the always-on Linux worker VM (self-hosted GitHub Actions runner host),
// optional Windows dev VM / Bastion, the Linux VM's Foundry/seeding RBAC, and the opt-in
// self-hosted GitHub runner (RBAC + PAT secret + runner extension LAST). Depends on 00/10.
module stage40 'stages/40-runner/40-runner.bicep' = {
  name: 'stage40-runner-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    foundrySpokeVnetName: stage00.outputs.foundrySpokeVnetName
    bastionSubnetId: stage00.outputs.bastionSubnetId
    vmSubnetName: stage00.outputs.vmSubnetName
    aiAccountName: stage13.outputs.aiAccountName
    projectNameDev: stage15dev.outputs.projectName
    projectNameTest: stage15test.outputs.projectName
    keyVaultName: stage10.outputs.keyVaultName
    vmAdminPassword: vmAdminPassword
    vmAdminUsername: vmAdminUsername
    deployWindowsVm: deployWindowsVm
    deployBastion: deployBastion
    githubRunnerRepoUrl: githubRunnerRepoUrl
    githubRunnerPat: githubRunnerPat
    githubRunnerPatSecretName: githubRunnerPatSecretName
    githubRunnerLabels: githubRunnerLabels
  }
  dependsOn: [
    stage00
    stage10
    stage13
    stage15dev
    stage15test
  ]
}


// ==================== OUTPUTS ====================
// Surfaced by azd as env vars (and typically mirrored to repo variables). Consumed by the
// in-VNet self-hosted workflows (the per-agent .github/workflows/deploy-*-agent.yml + reusable
// deploy-agent.yml, and deploy-agent-network.yml) which do the agent deploys / compliance / Teams
// publishing, and by the azd predown hook (capability-host cleanup + runner deregistration). azd
// itself runs nothing after
// provision.

@description('Resource group the deployment targets.')
output AZURE_RESOURCE_GROUP string = resourceGroup().name

@description('Name of the private Linux VM that hosts the in-VNet self-hosted GitHub Actions runner (also the predown hook\'s runner-deregistration target).')
output GITHUB_ACTIONS_RUNNER_VM_NAME string = stage40.outputs.vmName


@description('DEV Foundry project endpoint the seeded dev agents are created against.')
output AZURE_AI_PROJECT_ENDPOINT_DEV string = stage15dev.outputs.projectEndpoint

@description('TEST Foundry project endpoint the seeded test agents are created against.')
output AZURE_AI_PROJECT_ENDPOINT_TEST string = stage15test.outputs.projectEndpoint

@description('Foundry (Cognitive Services) account name. Used by the predown hook to delete capability hosts before teardown.')
output AZURE_AI_ACCOUNT_NAME string = stage13.outputs.aiAccountName

@description('DEV Foundry project name. Used by the predown hook to delete the dev project capability host before teardown.')
output AZURE_AI_PROJECT_NAME_DEV string = stage15dev.outputs.projectName

@description('TEST Foundry project name. Used by the predown hook to delete the test project capability host before teardown.')
output AZURE_AI_PROJECT_NAME_TEST string = stage15test.outputs.projectName

@description('Model deployment name assigned to the default seeded agent.')
output AZURE_AI_MODEL_DEPLOYMENT_NAME string = modelName

@description('Name of the strict RAI guardrail policy assignment (empty when disabled). Use to query compliance.')
output RAI_GUARDRAIL_ASSIGNMENT_NAME string = stage30.outputs.raiAssignmentName

@description('Name of the deliberately non-compliant demo deployment (empty when disabled).')
output NONCOMPLIANT_DEMO_DEPLOYMENT_NAME string = stage30.outputs.nonCompliantDeploymentName

@description('Whether to seed the second (model-gateway) agent. Always true — the model gateway is always deployed.')
output SEED_ENABLE_SECOND_AGENT bool = true

@description('Model reference for the second (model-gateway) agent.')
output SEED_SECOND_AGENT_MODEL string = stage30.outputs.agentModelReference

// ---- Teams / M365 publish (consumed by the in-VNet Teams-publish workflow path) ----

@description('Whether the Teams / M365 publish path was deployed. Always true.')
output SEED_ENABLE_TEAMS_PUBLISH bool = true

@description('Public FQDN of the YARP proxy — the Azure Bot Service messaging endpoint host.')
output TEAMS_YARP_FQDN string = stage10.outputs.yarpWebAppFqdn

@description('Name of the YARP proxy web app — the deploy-agent-network workflow patches its ReverseProxy__Routes__* appSettings to wire the per-agent edge routes (deny-by-default).')
output TEAMS_YARP_WEBAPP_NAME string = stage10.outputs.yarpWebAppName

@description('APIM instance name (the Teams-publish path pins the Teams API validate-jwt audience live once the bot App ID is known).')
output TEAMS_APIM_NAME string = apimName

@description('Name of the DEV APIM Teams inbound API (== its path).')
output TEAMS_APIM_API_NAME_DEV string = stage30.outputs.teamsApiNameDev

@description('Name of the TEST APIM Teams inbound API (== its path).')
output TEAMS_APIM_API_NAME_TEST string = stage30.outputs.teamsApiNameTest

@description('Entra tenant the single-tenant bot registration lives in.')
output TEAMS_TENANT_ID string = tenant().tenantId

@description('Suggested Azure Bot Service resource name the Teams-publish path creates (stable per environment).')
output TEAMS_BOT_NAME string = 'bot-${uniqueSuffix}'

@description('Environment unique suffix, prefixed onto each published agent display name so entries are unambiguous per deployment in a shared tenant catalog (e.g. "<suffix>-teams-agent").')
output TEAMS_NAME_PREFIX string = uniqueSuffix

@description('Log Analytics workspace resource ID — the Teams-publish path passes it to bot-service.bicep so the Bot Service diagnostic setting is codified (BotRequest logs -> workspace).')
output TEAMS_LOG_ANALYTICS_ID string = stage00.outputs.logAnalyticsId

@description('Per-environment DEV MCP server URL (the APIM MCP gateway) for the primary sample server. The reusable deploy-agent workflow injects this as the MCP tool `server_url` for dev agents.')
output MCP_GATEWAY_URL_DEV string = mcpSampleGatewayUrl

@description('Per-environment TEST MCP server URL (the APIM MCP gateway) for the primary sample server. The reusable deploy-agent workflow injects this as the MCP tool `server_url` for test agents.')
output MCP_GATEWAY_URL_TEST string = mcpSampleGatewayUrlTest

// --- MCP compliance (deploy-agent-network workflow) ---------------------------------
@description('APIM instance name — used by the deploy-agent-network workflow to re-apply the MCP rate-limit policies on demand.')
output MCP_COMPLIANCE_APIM_NAME string = apimName
@description('Number of MCP servers governed by the applied compliance policies (from mcp/mcp.json).')
output MCP_COMPLIANCE_SERVER_COUNT int = stage30.outputs.governedServerCount
@description('DEV MCP app registration audience the compliance policy validates the agent token against.')
output MCP_COMPLIANCE_AUDIENCE_DEV string = stage20dev.outputs.mcpAudience
@description('TEST MCP app registration audience the compliance policy validates the agent token against.')
output MCP_COMPLIANCE_AUDIENCE_TEST string = stage20test.outputs.mcpAudience

@description('Name of the DEV private MCP (agent-tools) web app. The predeploy/postdeploy hooks open and re-close its SCM site so azd can zip-deploy the Node source.')
output MCP_WEBAPP_NAME_DEV string = stage20dev.outputs.mcpWebAppName

@description('Name of the TEST private MCP (agent-tools) web app. The predeploy/postdeploy hooks open and re-close its SCM site so azd can zip-deploy the Node source.')
output MCP_WEBAPP_NAME_TEST string = stage20test.outputs.mcpWebAppName

// --- Foundry agent token governance (deploy-agent-network workflow) ----------------
@description('APIM instance name — used by the deploy-agent-network workflow to re-apply the Foundry agent token-limit policy on demand.')
output FOUNDRY_AGENTS_APIM_NAME string = apimName
@description('DEV APIM API resource name the deploy-agent-network workflow attaches the aggregated token-limit policy to.')
output FOUNDRY_AGENTS_API_NAME_DEV string = stage30.outputs.foundryAgentsApiNameDev
@description('TEST APIM API resource name the deploy-agent-network workflow attaches the aggregated token-limit policy to.')
output FOUNDRY_AGENTS_API_NAME_TEST string = stage30.outputs.foundryAgentsApiNameTest
@description('Primary Foundry account name — the deploy-agent-network workflow derives the backend entity ID from it.')
output FOUNDRY_AGENTS_ACCOUNT_NAME string = stage13.outputs.aiAccountName
@description('Optional caller audience the foundry-agents API validates (empty = tenant + signature only).')
output FOUNDRY_AGENTS_AUDIENCE string = agentCallerAudience
@description('Public path of the governed DEV Foundry agent /responses API (<account>/<project-dev>).')
output FOUNDRY_AGENTS_API_PATH_DEV string = stage30.outputs.foundryAgentsApiPathDev
@description('Public path of the governed TEST Foundry agent /responses API (<account>/<project-test>).')
output FOUNDRY_AGENTS_API_PATH_TEST string = stage30.outputs.foundryAgentsApiPathTest

// ---- Self-hosted GitHub runner (consumed by the predown hook to deregister on teardown) ----

@description('GitHub repo URL the self-hosted runner registered against. Empty when the runner was not installed; gates the predown hook deregistration phase.')
output GITHUB_RUNNER_REPO_URL string = githubRunnerRepoUrl

@description('Key Vault (DNS) name holding the runner PAT. The VM bootstrap reads it over the private data plane to mint a runner registration token at provision time.')
output KEY_VAULT_NAME string = keyVaultName

@description('Name of the Key Vault secret holding the runner PAT.')
output GITHUB_RUNNER_PAT_SECRET_NAME string = githubRunnerPatSecretName

@description('Local account the runner service runs as (the VM admin user), set by the VM bootstrap.')
output GITHUB_RUNNER_USER string = vmAdminUsername

@description('Name of the private Azure Container Registry. The deploy-hosted-agent workflow runs `az acr build` against it (server-side build, no Docker daemon on the runner) and pushes the hosted-agent image the Foundry project pulls to run the agent.')
output AZURE_CONTAINER_REGISTRY_NAME string = stage10.outputs.acrName

@description('Name of the Azure API Center that inventories the platform APIs (continuously synced from APIM).')
output AZURE_API_CENTER_NAME string = stage11.outputs.apiCenterName