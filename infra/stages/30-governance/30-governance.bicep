/*
Stage 30 — GOVERNANCE.

Everything that governs the platform + workload AFTER they exist: the Foundry project's
MCP connections, the APIM model-gateway API/policy/connection wiring, the Teams inbound API
(optional), the RAI guardrail audit policy (+ its non-compliant demo, optional), the APIM
lockdown that flips public access OFF, and the cross-spoke gateway firewall rules.

Depends only downward on stages 00/10/20 (their outputs are threaded in as params). Two hard
orderings are preserved from the flat template:
  * apimLockdown runs STRICTLY LAST — after every APIM API/policy write (api-policy,
    teams-api, mcp-compliance) — because it forbids further public-plane writes once
    publicNetworkAccess flips to 'Disabled'. The whole stage already runs after stage20/10.
  * gatewayFirewallRules is sequenced after the platform so its rule-collection-group PUT
    lands well after firewall.bicep's default group (avoids the back-to-back-PUT fault).
YARP is never private-endpointed; nothing here changes that.
*/

param location string
param uniqueSuffix string

// ---- stage 10 (platform) facts ----
param aiAccountName string
param apimName string
param providerAccountId string
param gatewayUrl string

// ---- stage 15 (per-env Foundry project) facts ----
@description('Dev Foundry project name.')
param projectNameDev string
@description('Test Foundry project name.')
param projectNameTest string
@description('Dev Foundry project resource id (caller pinned in the shared model-gateway provider policy — dev is the primary).')
param projectIdDev string

// ---- stage 20 (per-env MCP workload) facts ----
@description('Governed MCP servers for DEV (from stage 20): each { connectionName, url } — the APIM MCP gateway servers.')
param serversDev array
@description('Governed MCP servers for TEST (from stage 20).')
param serversTest array
@description('DEV MCP app-registration audience (from stage 20) the agent token is minted for.')
param mcpAudienceDev string
@description('TEST MCP app-registration audience (from stage 20).')
param mcpAudienceTest string

// ---- stage 00 (foundation) facts ----
param modelGatewayApimSubnetId string

// ---- model-gateway API wiring ----
param providerBackendBaseUrl string
param gatewayCallerAppId string
param modelGatewayConnectionName string
param gatewayModelName string

// ---- firewall (cross-spoke) rule CIDRs ----
param firewallPolicyName string
param agentSubnetCidr string
param modelGatewayPeSubnetCidr string
param modelGatewayApimSubnetCidr string
param foundryPeSubnetCidr string
param appServicePeSubnetCidr string

// ---- Teams / M365 publish ----
@description('DEV bot Microsoft App IDs allowed as APIM validate-jwt audiences on the dev Teams API. Empty = validate the Bot Framework issuer only.')
param teamsBotAppIdsDev array = []
@description('TEST bot Microsoft App IDs allowed as APIM validate-jwt audiences on the test Teams API.')
param teamsBotAppIdsTest array = []

// ---- RAI guardrail (optional) ----
param enableRaiGuardrailPolicy bool
param enableNonCompliantModelDemo bool
param modelName string
param modelFormat string
param modelVersion string
param modelSkuName string

// ---- Foundry agent token governance ----
@description('Optional audience the caller Entra token must carry for the foundry-agents API (empty = validate tenant + signature only).')
param agentCallerAudience string = ''

// One Foundry project connection per governed MCP server, PER project (dev + test). These
// connections are not used by the Agents capability host, so they run here (stage 30) rather
// than at project-create time. Each env's project points at its own env-suffixed MCP server.
var mcpConnectionsDev = map(serversDev, srv => {
  name: srv.connectionName
  url: '${srv.url}/'
  audience: mcpAudienceDev
})
var mcpConnectionsTest = map(serversTest, srv => {
  name: srv.connectionName
  url: '${srv.url}/'
  audience: mcpAudienceTest
})

module projectMcpConnectionsDev './foundry/project-mcp-connections.bicep' = {
  name: 'project-mcp-connections-dev-${uniqueSuffix}-deployment'
  params: {
    accountName: aiAccountName
    projectName: projectNameDev
    mcpConnections: mcpConnectionsDev
  }
}

module projectMcpConnectionsTest './foundry/project-mcp-connections.bicep' = {
  name: 'project-mcp-connections-test-${uniqueSuffix}-deployment'
  params: {
    accountName: aiAccountName
    projectName: projectNameTest
    mcpConnections: mcpConnectionsTest
  }
}

// ==================== RAI GUARDRAIL POLICY (AUDIT) ====================
// Assigns the built-in "[Preview]: Guardrail for Cognitive Services Deployments"
// initiative with STRICT parameters. Audit-only (the built-in cannot block); it
// reports every model deployment's content-filter config as Compliant / Non-compliant.
module raiGuardrail './governance/rai-guardrail-assignment.bicep' = if (enableRaiGuardrailPolicy) {
  name: 'rai-guardrail-${uniqueSuffix}-deployment'
}

// DEMO: a deliberately non-compliant deployment (weak custom RAI policy) so you can
// watch the guardrail flag it. Attaches to the existing AI Services account.
module nonCompliantModelDemo './governance/noncompliant-model-demo.bicep' = if (enableNonCompliantModelDemo) {
  name: 'noncompliant-demo-${uniqueSuffix}-deployment'
  params: {
    accountName: aiAccountName
    modelName: modelName
    modelFormat: modelFormat
    modelVersion: modelVersion
    modelSkuName: modelSkuName
  }
}

// MCP per-agent rate-limit compliance policies — reflect mcp/mcp-policy.json into a policy on
// each MCP server's API so each agent's tool calls are throttled by AppId (deny-by-default,
// per server). Applied PER ENV here at provision time so a fresh environment starts compliant;
// the deploy-agent-network workflow re-applies THIS SAME module (per env) after the JSON changes.
module apimMcpComplianceAllDev './model-gateway/apim-mcp-compliance-all.bicep' = {
  name: 'mcp-compliance-all-dev-${uniqueSuffix}-deployment'
  params: {
    apimName: apimName
    env: 'dev'
    mcpAudience: mcpAudienceDev
    tenantId: tenant().tenantId
  }
}

module apimMcpComplianceAllTest './model-gateway/apim-mcp-compliance-all.bicep' = {
  name: 'mcp-compliance-all-test-${uniqueSuffix}-deployment'
  params: {
    apimName: apimName
    env: 'test'
    mcpAudience: mcpAudienceTest
    tenantId: tenant().tenantId
  }
}

module apimApiPolicy './model-gateway/apim-api-policy.bicep' = {
  name: 'model-gateway-apim-api-${uniqueSuffix}-deployment'
  params: {
    apimName: apimName
    backendBaseUrl: providerBackendBaseUrl
    providerAccountResourceId: providerAccountId
    projectMiClientId: gatewayCallerAppId
    callerProjectResourceId: projectIdDev
  }
}

// Advertise APIM to the DEV (primary) Foundry project as an ApiManagement connection. The
// shared model-gateway provider passthrough is a single instance pinned to the primary project.
module apimConnection './model-gateway/apim-connection.bicep' = {
  name: 'model-gateway-connection-${uniqueSuffix}-deployment'
  params: {
    aiFoundryName: aiAccountName
    projectName: projectNameDev
    connectionName: modelGatewayConnectionName
    apimGatewayUrl: gatewayUrl
    apiPath: apimApiPolicy.outputs.apiPath
    exposedModelName: gatewayModelName
  }
}

// APIM Teams / M365 inbound API + policy, PER ENV (validate Bot Framework JWT, forward to the
// per-env project's agent activityProtocol endpoint on the primary Foundry PE). Always deployed.
module apimTeamsApiDev './model-gateway/apim-teams-api.bicep' = {
  name: 'teams-apim-api-dev-${uniqueSuffix}-deployment'
  params: {
    apimName: apimName
    env: 'dev'
    foundryAccountName: aiAccountName
    projectName: projectNameDev
    botAppIds: teamsBotAppIdsDev
    expectedTenantId: tenant().tenantId
  }
}

module apimTeamsApiTest './model-gateway/apim-teams-api.bicep' = {
  name: 'teams-apim-api-test-${uniqueSuffix}-deployment'
  params: {
    apimName: apimName
    env: 'test'
    foundryAccountName: aiAccountName
    projectName: projectNameTest
    botAppIds: teamsBotAppIdsTest
    expectedTenantId: tenant().tenantId
  }
}

// APIM Foundry agent /responses inbound API (structure) + token-governance policy, PER ENV. The
// API is created once here; the deny-by-default token-limit + llm-emit-token-metric policy is
// applied with an EMPTY allowlist at provision (deny-all) and re-applied with the aggregated
// per-env agents/<name>/agent-network.json by the deploy-agent-network workflow. Always deployed.
module apimFoundryAgentsApiDev './model-gateway/apim-foundry-agents-api.bicep' = {
  name: 'foundry-agents-apim-api-dev-${uniqueSuffix}-deployment'
  params: {
    apimName: apimName
    env: 'dev'
    foundryAccountName: aiAccountName
    projectName: projectNameDev
  }
}

module apimFoundryAgentsApiTest './model-gateway/apim-foundry-agents-api.bicep' = {
  name: 'foundry-agents-apim-api-test-${uniqueSuffix}-deployment'
  params: {
    apimName: apimName
    env: 'test'
    foundryAccountName: aiAccountName
    projectName: projectNameTest
  }
}

module apimFoundryAgentLimitsDev './model-gateway/apim-foundry-agent-limits.bicep' = {
  name: 'foundry-agent-limits-dev-${uniqueSuffix}-deployment'
  params: {
    apimName: apimName
    apiName: apimFoundryAgentsApiDev.outputs.apiName
    env: 'dev'
    foundryAccountName: aiAccountName
    projectName: projectNameDev
    tenantId: tenant().tenantId
    callerAudience: agentCallerAudience
  }
}

module apimFoundryAgentLimitsTest './model-gateway/apim-foundry-agent-limits.bicep' = {
  name: 'foundry-agent-limits-test-${uniqueSuffix}-deployment'
  params: {
    apimName: apimName
    apiName: apimFoundryAgentsApiTest.outputs.apiName
    env: 'test'
    foundryAccountName: aiAccountName
    projectName: projectNameTest
    tenantId: tenant().tenantId
    callerAudience: agentCallerAudience
    // agentLimits omitted -> DENY-ALL until the deploy-agent-network workflow supplies the
    // aggregated agents/<name>/agent-network.json allowlist.
  }
}

// Phase 2 lockdown: flip APIM publicNetworkAccess to 'Disabled' now that the inbound
// private endpoint exists (APIM forbids 'Disabled' at create time). Runs after the PE
// and after the API/policy children so it never races their creation.
module apimLockdown './model-gateway/apim-lockdown.bicep' = {
  name: 'model-gateway-apim-lockdown-${uniqueSuffix}-deployment'
  params: {
    apimName: apimName
    location: location
    apimOutboundSubnetId: modelGatewayApimSubnetId
  }
  dependsOn: [
    apimApiPolicy
    apimTeamsApiDev
    apimTeamsApiTest
    apimMcpComplianceAllDev
    apimMcpComplianceAllTest
    apimFoundryAgentLimitsDev
    apimFoundryAgentLimitsTest
  ]
}

// Gateway firewall rules (ALWAYS on — APIM is always-on): APIM platform egress, plus the
// model-gateway (agent -> APIM PE) and Teams (APIM -> Foundry PE) cross-spoke allows.
// Deliberately sequenced AFTER the APIM deployment: APIM Standard v2 takes ~15-45 min to
// provision, which leaves the firewall long-idle after firewall.bicep's defaultRuleGroup
// PUT before this second rule-collection-group PUT lands on the same policy. This avoids
// the transient "faulted referenced firewalls" fault Basic-tier firewalls hit when two
// rule-collection-group PUTs arrive back-to-back.
module gatewayFirewallRules './model-gateway/gateway-firewall-rules.bicep' = {
  name: 'gateway-fwall-rules-${uniqueSuffix}-deployment'
  params: {
    firewallPolicyName: firewallPolicyName
    agentSubnetCidr: agentSubnetCidr
    modelGatewayPeSubnetCidr: modelGatewayPeSubnetCidr
    modelGatewayApimSubnetCidr: modelGatewayApimSubnetCidr
    foundryPeSubnetCidr: foundryPeSubnetCidr
    appServicePeSubnetCidr: appServicePeSubnetCidr
  }
}

@description('RAI guardrail assignment name (empty when the policy is disabled).')
output raiAssignmentName string = enableRaiGuardrailPolicy ? raiGuardrail!.outputs.assignmentName : ''

@description('Non-compliant demo deployment name (empty when the demo is disabled).')
output nonCompliantDeploymentName string = enableNonCompliantModelDemo ? nonCompliantModelDemo!.outputs.deploymentName : ''

@description('Model reference (connection/model) advertised to the second, model-gateway agent.')
output agentModelReference string = apimConnection.outputs.agentModelReference

@description('APIM DEV Teams inbound API name.')
output teamsApiNameDev string = apimTeamsApiDev.outputs.apiName

@description('APIM TEST Teams inbound API name.')
output teamsApiNameTest string = apimTeamsApiTest.outputs.apiName

@description('Number of MCP servers governed by the applied compliance policies (per env; same count).')
output governedServerCount int = apimMcpComplianceAllDev.outputs.governedServerCount

@description('APIM API name for the governed DEV Foundry agent /responses endpoint.')
output foundryAgentsApiNameDev string = apimFoundryAgentsApiDev.outputs.apiName

@description('APIM API name for the governed TEST Foundry agent /responses endpoint.')
output foundryAgentsApiNameTest string = apimFoundryAgentsApiTest.outputs.apiName

@description('Public path of the governed DEV Foundry agent /responses API (<account>/<project-dev>).')
output foundryAgentsApiPathDev string = apimFoundryAgentsApiDev.outputs.apiPath

@description('Public path of the governed TEST Foundry agent /responses API (<account>/<project-test>).')
output foundryAgentsApiPathTest string = apimFoundryAgentsApiTest.outputs.apiPath
