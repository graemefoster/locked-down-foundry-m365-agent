/*
Stage 13 — Foundry account (orchestrator)

The Foundry (AI Services) account is the centrepiece of the whole platform, so it
gets its own stage carrying EVERYTHING that stands the account up and protects it:

  foundry/ai-services-account.bicep            → the account + model deployment + SMI
                                                 + VNet injection + diagnostics
  network/ai-account-private-endpoint.bicep    → the account private endpoint + DNS
  rbac/keyvault-account-role-assignment.bicep  → account SMI → Key Vault Crypto User (CMK)
  rbac/app-insights-account-role-assignment.bicep → account SMI → Log Analytics Reader
  encryption/ai-account-encryption.bicep       → re-PUT the account with CMK encryption

Runs AFTER stage 10 (needs Key Vault + the DNS zones + the data substrate). The
project (its data-plane RBAC + capability host) lives in stage 15.
*/

param location string
param uniqueSuffix string

// Account + model.
param accountName string
param modelName string
param modelFormat string
param modelVersion string
param modelSkuName string
param modelCapacity int

// From stage 00 (observability + networking).
param agentSubnetId string
param logAnalyticsId string
param appInsightsConnectionString string
param appInsightsId string
param appInsightsName string
param foundrySpokeVnetName string
param foundryPeSubnetName string
param aiServicesDnsZoneId string
param openAiDnsZoneId string
param cognitiveServicesDnsZoneId string

// Key Vault (CMK) — from stage 10 data resources.
param keyVaultName string
param keyVaultUri string
param keyName string
param keyUriWithVersion string

// Foundry account egress posture — shared by BOTH the identity (create) and encryption
// (CMK re-PUT) declarations of the account. A CognitiveServices account update is a full PUT,
// so both declarations must agree on these network properties or they silently drift (the
// encryption module deploys last and wins). Define once here and pass to both.
var foundryRestrictOutboundNetworkAccess = false
var foundryAllowedFqdnList = []

module aiAccount './foundry/ai-services-account.bicep' = {
  name: 'ai-${accountName}-${uniqueSuffix}-deployment'
  params: {
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
    restrictOutboundNetworkAccess: foundryRestrictOutboundNetworkAccess
    allowedFqdnList: foundryAllowedFqdnList
  }
}


module appInsightsAccountRoleAssignment './rbac/app-insights-account-role-assignment.bicep' = {
  name: 'appi-account-ra-${uniqueSuffix}-deployment'
  params: {
    appInsightsName: appInsightsName
    accountPrincipalId: aiAccount.outputs.accountPrincipalId
  }
}

// Grant the account SMI Key Vault Crypto User BEFORE the CMK re-PUT (KV data-plane role
// must be effective first).
module keyVaultAccountRoleAssignment './rbac/keyvault-account-role-assignment.bicep' = {
  name: 'keyvault-account-rbac-${uniqueSuffix}-deployment'
  params: {
    keyVaultName: keyVaultName
    aiServicesPrincipalId: aiAccount.outputs.accountPrincipalId
  }
}

module aiAccountEncryption './encryption/ai-account-encryption.bicep' = {
  name: 'ai-encryption-${uniqueSuffix}-deployment'
  params: {
    accountName: aiAccount.outputs.accountName
    location: location
    keyVaultUri: keyVaultUri
    keyName: keyName
    keyVersion: last(split(keyUriWithVersion, '/'))
    agentSubnetId: agentSubnetId
    restrictOutboundNetworkAccess: foundryRestrictOutboundNetworkAccess
    allowedFqdnList: foundryAllowedFqdnList
  }
  dependsOn: [
    keyVaultAccountRoleAssignment
  ]
}

module aiAccountPrivateEndpoint './network/ai-account-private-endpoint.bicep' = {
  name: 'stage13-account-pe-${uniqueSuffix}'
  params: {
    aiAccountName: aiAccount.outputs.accountName
    foundrySpokeVnetName: foundrySpokeVnetName
    foundryPeSubnetName: foundryPeSubnetName
    aiServicesDnsZoneId: aiServicesDnsZoneId
    openAiDnsZoneId: openAiDnsZoneId
    cognitiveServicesDnsZoneId: cognitiveServicesDnsZoneId
  }
  dependsOn: [
    aiAccountEncryption //slow things down. Been getting some private-endpoint errors as Foundry not ready.
  ]
}


output aiAccountName string = aiAccount.outputs.accountName
output accountPrincipalId string = aiAccount.outputs.accountPrincipalId
