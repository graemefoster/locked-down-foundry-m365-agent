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
worker VM, so this defaults to FALSE — you only pay the Windows licence, compute
and Bastion cost when you explicitly opt in with
`azd env set DEPLOY_WINDOWS_VM true`.
''')
param deployWindowsVm bool = false

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
    enableTeamsPublish: enableTeamsPublish
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
// The Foundry platform on the stage 00 substrate: the AI Services account + model,
// Key Vault (CMK) + dependent resources (Storage/Cosmos/Search/App Service) + ACR,
// private endpoints & DNS, the model gateway (provider Foundry + APIM + the MCP
// gateway wiring), the AI project, data-plane RBAC + capability host, and the CMK
// re-PUT of the account/storage.

// Storage SKU — no-ZRS regions fall back to GRS. Computed in main because stage 00
// (flow-logs storage) consumes it too; also threaded into stage 10 (storage CMK re-PUT).
var noZRSRegions = ['southindia', 'westus', 'northcentralus']
var storageSkuName = contains(noZRSRegions, location) ? 'Standard_GRS' : 'Standard_ZRS'

module stage10 'stages/10-platform/10-platform.bicep' = {
  name: 'stage10-platform-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    accountName: accountName
    modelName: modelName
    modelFormat: modelFormat
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity
    appServicePlanName: appServicePlanName
    keyVaultName: keyVaultName
    azureStorageName: azureStorageName
    aiSearchName: aiSearchName
    cosmosDBName: cosmosDBName
    acrName: acrName
    appInsightsName: appInsightsName
    enableTeamsPublish: enableTeamsPublish
    apimGatewayUrl: apimGatewayUrl
    projectName: projectName
    projectDescription: projectDescription
    displayName: displayName
    projectCapHost: projectCapHost
    storageSkuName: storageSkuName
    providerAccountName: providerAccountName
    apimName: apimName
    gatewayModelName: gatewayModelName
    gatewayModelFormat: gatewayModelFormat
    gatewayModelVersion: gatewayModelVersion
    gatewayModelSkuName: gatewayModelSkuName
    gatewayModelCapacity: gatewayModelCapacity
    agentSubnetId: stage00.outputs.agentSubnetId
    logAnalyticsId: stage00.outputs.logAnalyticsId
    appInsightsConnectionString: stage00.outputs.appInsightsConnectionString
    appInsightsId: stage00.outputs.appInsightsId
    appServiceDelegatedSubnetId: stage00.outputs.appServiceDelegatedSubnetId
    hubVnetId: stage00.outputs.hubVnetId
    foundrySpokeVnetName: stage00.outputs.foundrySpokeVnetName
    foundryPeSubnetName: stage00.outputs.foundryPeSubnetName
    modelGatewayApimSubnetId: stage00.outputs.modelGatewayApimSubnetId
    modelGatewayPeSubnetId: stage00.outputs.modelGatewayPeSubnetId
    aiServicesDnsZoneId: stage00.outputs.aiServicesDnsZoneId
    openAiDnsZoneId: stage00.outputs.openAiDnsZoneId
    cognitiveServicesDnsZoneId: stage00.outputs.cognitiveServicesDnsZoneId
    aiSearchDnsZoneId: stage00.outputs.aiSearchDnsZoneId
    storageDnsZoneId: stage00.outputs.storageDnsZoneId
    cosmosDBDnsZoneId: stage00.outputs.cosmosDBDnsZoneId
    acrDnsZoneId: stage00.outputs.acrDnsZoneId
    keyVaultDnsZoneId: stage00.outputs.keyVaultDnsZoneId
  }
}

// ==================== STAGE 20 — WORKLOAD: MCP ====================
// The governed MCP workload on top of the stage 10 platform: the private MCP web app
// + its MI-as-FIC identity + private endpoint, the guarding Entra app registration, the
// APIM MCP server API(s) fronting it, and App Service built-in auth on the web app.
module stage20 'stages/20-workload-mcp/20-workload-mcp.bicep' = {
  name: 'stage20-workload-mcp-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
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

// URL of the sample MCP server (the first configured server) that the deploy-test-agent-one
// workflow injects as test-agent-one's `server_url`. first() is safe: mcp/mcp.json always has >=1
// server, and the sample 'mcp' server is the first entry by convention.
var mcpSampleGatewayUrl = '${first(stage20.outputs.servers).url}/'

// ==================== STAGE 30 — GOVERNANCE ====================
// Post-platform governance: project MCP connections, APIM API/policy/connection + Teams API,
// RAI guardrail (+ non-compliant demo), APIM lockdown (STRICTLY LAST), and cross-spoke gateway
// firewall rules. Depends only downward on stages 00/10/20 (their outputs are threaded in).
module stage30 'stages/30-governance/30-governance.bicep' = {
  name: 'stage30-governance-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    aiAccountName: stage10.outputs.aiAccountName
    projectName: stage10.outputs.projectName
    apimName: stage10.outputs.apimName
    providerAccountId: stage10.outputs.providerAccountId
    projectId: stage10.outputs.projectId
    gatewayUrl: stage10.outputs.gatewayUrl
    servers: stage20.outputs.servers
    mcpAudience: stage20.outputs.mcpAudience
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
    enableTeamsPublish: enableTeamsPublish
    teamsBotAppIds: teamsBotAppIds
    enableRaiGuardrailPolicy: enableRaiGuardrailPolicy
    enableNonCompliantModelDemo: enableNonCompliantModelDemo
    modelName: modelName
    modelFormat: modelFormat
    modelVersion: modelVersion
    modelSkuName: modelSkuName
  }
  dependsOn: [
    stage00
    stage10
    stage20
  ]
}


// ==================== STAGE 40 — RUNNER ====================
// In-VNet compute: the always-on Linux worker VM (seed-agents run-command target + self-hosted
// runner host), optional Windows dev VM / Bastion, the Linux VM's seeding RBAC, and the opt-in
// self-hosted GitHub runner (RBAC + PAT secret + runner extension LAST). Depends on 00/10.
module stage40 'stages/40-runner/40-runner.bicep' = {
  name: 'stage40-runner-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    foundrySpokeVnetName: stage00.outputs.foundrySpokeVnetName
    vmSubnetName: stage00.outputs.vmSubnetName
    aiAccountName: stage10.outputs.aiAccountName
    projectName: stage10.outputs.projectName
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
  ]
}


// ==================== OUTPUTS (consumed by the azd predeploy hook) ====================

@description('Resource group the deployment targets.')
output AZURE_RESOURCE_GROUP string = resourceGroup().name

@description('Name of the private Linux VM the seed-agents hook runs its script on.')
output SEED_AGENTS_VM_NAME string = stage40.outputs.vmName


@description('Foundry project endpoint the seeded agents are created against.')
output AZURE_AI_PROJECT_ENDPOINT string = stage10.outputs.projectEndpoint

@description('Foundry (Cognitive Services) account name. Used by the predown hook to delete capability hosts before teardown.')
output AZURE_AI_ACCOUNT_NAME string = stage10.outputs.aiAccountName

@description('Foundry project name. Used by the predown hook to delete capability hosts before teardown.')
output AZURE_AI_PROJECT_NAME string = stage10.outputs.projectName

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

// ---- Teams / M365 publish (consumed by the postdeploy hook) ----

@description('Whether the Teams / M365 publish path was deployed (gates the postdeploy hook).')
output SEED_ENABLE_TEAMS_PUBLISH bool = enableTeamsPublish

@description('Comma-separated names of the seeded agents to publish to Teams / M365 (the postdeploy hook creates one bot per agent, endpoint /teams/<agentName>).')
output TEAMS_PUBLISH_AGENT_NAMES string = join(teamsPublishAgentNames, ',')

@description('Public FQDN of the YARP proxy — the Azure Bot Service messaging endpoint host.')
output TEAMS_YARP_FQDN string = stage10.outputs.yarpWebAppFqdn

@description('APIM instance name (hook pins the Teams API validate-jwt audience live once the bot App ID is known).')
output TEAMS_APIM_NAME string = apimName

@description('Name of the APIM Teams inbound API (== its path).')
output TEAMS_APIM_API_NAME string = stage30.outputs.teamsApiName

@description('Entra tenant the single-tenant bot registration lives in.')
output TEAMS_TENANT_ID string = tenant().tenantId

@description('Suggested Azure Bot Service resource name the postdeploy hook creates (stable per environment).')
output TEAMS_BOT_NAME string = 'bot-${uniqueSuffix}'

@description('Environment unique suffix, prefixed onto each published agent display name so entries are unambiguous per deployment in a shared tenant catalog (e.g. "<suffix>-teams-agent").')
output TEAMS_NAME_PREFIX string = uniqueSuffix

@description('Log Analytics workspace resource ID — the postdeploy hook passes it to bot-service.bicep so the Bot Service diagnostic setting is codified (BotRequest logs -> workspace).')
output TEAMS_LOG_ANALYTICS_ID string = stage00.outputs.logAnalyticsId

@description('Per-environment MCP server URL (the APIM MCP gateway) for the primary sample server, identical to the target of the testweathermcpserver project connection. The deploy-test-agent-one workflow injects this as the MCP tool `server_url` so agents/test-agent-one/agent.yaml stays env-agnostic (the Foundry MCP tool schema requires one of server_url/connector_id/tunnel_id even when a project connection supplies auth).')
output MCP_GATEWAY_URL string = mcpSampleGatewayUrl

// --- MCP compliance (deploy-compliancy workflow) ---------------------------------
@description('APIM instance name — used by the deploy-compliancy workflow to re-apply the MCP rate-limit policies on demand.')
output MCP_COMPLIANCE_APIM_NAME string = apimName
@description('Number of MCP servers governed by the applied compliance policies (from mcp/mcp.json).')
output MCP_COMPLIANCE_SERVER_COUNT int = stage30.outputs.governedServerCount
@description('MCP app registration audience the compliance policy validates the agent token against.')
output MCP_COMPLIANCE_AUDIENCE string = stage20.outputs.mcpAudience

// ---- Self-hosted GitHub runner (consumed by the predown hook to deregister on teardown) ----

@description('GitHub repo URL the self-hosted runner registered against. Empty when the runner was not installed; gates the predown hook deregistration phase.')
output GITHUB_RUNNER_REPO_URL string = githubRunnerRepoUrl

@description('Key Vault (DNS) name holding the runner PAT. The predown hook reads it on the VM (private data plane) to mint a runner remove-token before teardown.')
output KEY_VAULT_NAME string = keyVaultName

@description('Name of the Key Vault secret holding the runner PAT.')
output GITHUB_RUNNER_PAT_SECRET_NAME string = githubRunnerPatSecretName

@description('Local account the runner service runs as (the VM admin user). The predown hook runs `config.sh remove` as this user.')
output GITHUB_RUNNER_USER string = vmAdminUsername
