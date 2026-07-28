/*
Stage 10 slice — Foundry account (identity/create).
The primary AI Services (Cognitive Services) account + its model deployment,
system-assigned identity, VNet injection into the agent subnet and diagnostics.
The CMK re-PUT lives in the encryption slice; both must agree on the egress
posture (restrictOutboundNetworkAccess / allowedFqdnList), so those are threaded
in from the orchestrator (defined once) rather than recomputed here.
*/

param location string
param uniqueSuffix string
param accountName string

param modelName string
param modelFormat string
param modelVersion string
param modelSkuName string
param modelCapacity int

param appServicePlanName string

// From stage 00 (observability + networking).
param agentSubnetId string
param logAnalyticsId string
param appInsightsConnectionString string
param appInsightsId string

// Shared egress posture (defined once in the orchestrator, passed to account + encryption).
param restrictOutboundNetworkAccess bool
param allowedFqdnList array

module aiAccount './foundry/ai-account-identity.bicep' = {
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
    agentSubnetId: agentSubnetId
    logAnalyticsWorkspaceId: logAnalyticsId
    appInsightsConnectionString: appInsightsConnectionString
    appInsightsResourceId: appInsightsId
    mcpServerName: 'mcp-${appServicePlanName}.azurewebsites.net'
    restrictOutboundNetworkAccess: restrictOutboundNetworkAccess
    allowedFqdnList: allowedFqdnList
  }
}

output accountName string = aiAccount.outputs.accountName
output accountPrincipalId string = aiAccount.outputs.accountPrincipalId
