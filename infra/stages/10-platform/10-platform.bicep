/*
Stage 10 — Platform (orchestrator)

The Foundry platform on top of the stage 00 substrate. Composes the slices —
  foundry-account.bicep        → AI Services account + model deployment
  data-resources.bicep         → Key Vault, dependent resources (Storage/Cosmos/
                                 Search/App Service), container registry
  private-endpoints.bicep      → private endpoints + privatelink DNS
  model-gateway-platform.bicep → provider Foundry, APIM, APIM/provider PEs, APIM
                                 provider RBAC
  project.bicep                → AI project + workspace-id GUID
  rbac.bicep                   → data-plane RBAC + Agents capability host
  encryption.bicep             → CMK RBAC + account/storage CMK re-PUT

Consumes main params/vars + stage 00 outputs; re-exposes the names/ids/urls the
still-in-main modules (VM RBAC, runner, Teams/M365 + APIM policy children) read.
*/

param location string
param uniqueSuffix string

// Foundry account + model.
param accountName string
param modelName string
param modelFormat string
param modelVersion string
param modelSkuName string
param modelCapacity int

// Dependent resource + naming.
param appServicePlanName string
param keyVaultName string
param azureStorageName string
param aiSearchName string
param cosmosDBName string
param acrName string
param appInsightsName string
param enableTeamsPublish bool
param apimGatewayUrl string

// Project.
param projectName string
param projectDescription string
param displayName string
param projectCapHost string

// Storage SKU (computed in main; stage 00 needs it too).
param storageSkuName string

// Model gateway.
param providerAccountName string
param apimName string
param gatewayModelName string
param gatewayModelFormat string
param gatewayModelVersion string
param gatewayModelSkuName string
param gatewayModelCapacity int

// From stage 00 (observability + networking).
param agentSubnetId string
param logAnalyticsId string
param appInsightsConnectionString string
param appInsightsId string
param appServiceDelegatedSubnetId string
param hubVnetId string
param foundrySpokeVnetName string
param foundryPeSubnetName string
param modelGatewayApimSubnetId string
param modelGatewayPeSubnetId string

// Private DNS zone ids (created early in stage 00 foundation).
param aiServicesDnsZoneId string
param openAiDnsZoneId string
param cognitiveServicesDnsZoneId string
param aiSearchDnsZoneId string
param storageDnsZoneId string
param cosmosDBDnsZoneId string
param acrDnsZoneId string
param keyVaultDnsZoneId string

// Foundry account egress posture — shared by BOTH the identity (create) and encryption
// (CMK re-PUT) declarations of the account. A CognitiveServices account update is a full PUT,
// so both declarations must agree on these network properties or they silently drift (the
// encryption module deploys last and wins). Define once here and pass to both slices.
var foundryRestrictOutboundNetworkAccess = false
var foundryAllowedFqdnList = []

module foundryAccount 'foundry-account.bicep' = {
  name: 'stage10-foundry-account-${uniqueSuffix}'
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
    agentSubnetId: agentSubnetId
    logAnalyticsId: logAnalyticsId
    appInsightsConnectionString: appInsightsConnectionString
    appInsightsId: appInsightsId
    restrictOutboundNetworkAccess: foundryRestrictOutboundNetworkAccess
    allowedFqdnList: foundryAllowedFqdnList
  }
}

module dataResources 'data-resources.bicep' = {
  name: 'stage10-data-resources-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    keyVaultName: keyVaultName
    azureStorageName: azureStorageName
    aiSearchName: aiSearchName
    cosmosDBName: cosmosDBName
    acrName: acrName
    appServicePlanName: appServicePlanName
    appInsightsName: appInsightsName
    enableTeamsPublish: enableTeamsPublish
    foundryName: foundryAccount.outputs.accountName
    apimGatewayUrl: apimGatewayUrl
    logAnalyticsId: logAnalyticsId
    appServiceDelegatedSubnetId: appServiceDelegatedSubnetId
  }
}

module privateEndpoints 'private-endpoints.bicep' = {
  name: 'stage10-private-endpoints-${uniqueSuffix}'
  params: {
    uniqueSuffix: uniqueSuffix
    aiAccountName: foundryAccount.outputs.accountName
    aiSearchName: dataResources.outputs.aiSearchName
    storageName: dataResources.outputs.azureStorageName
    cosmosDBName: dataResources.outputs.cosmosDBName
    acrName: dataResources.outputs.acrName
    keyVaultName: dataResources.outputs.keyVaultName
    foundrySpokeVnetName: foundrySpokeVnetName
    foundryPeSubnetName: foundryPeSubnetName
    aiServicesDnsZoneId: aiServicesDnsZoneId
    openAiDnsZoneId: openAiDnsZoneId
    cognitiveServicesDnsZoneId: cognitiveServicesDnsZoneId
    aiSearchDnsZoneId: aiSearchDnsZoneId
    storageDnsZoneId: storageDnsZoneId
    cosmosDBDnsZoneId: cosmosDBDnsZoneId
    acrDnsZoneId: acrDnsZoneId
    keyVaultDnsZoneId: keyVaultDnsZoneId
  }
}

module modelGateway 'model-gateway-platform.bicep' = {
  name: 'stage10-model-gateway-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    providerAccountName: providerAccountName
    gatewayModelName: gatewayModelName
    gatewayModelFormat: gatewayModelFormat
    gatewayModelVersion: gatewayModelVersion
    gatewayModelSkuName: gatewayModelSkuName
    gatewayModelCapacity: gatewayModelCapacity
    apimName: apimName
    logAnalyticsId: logAnalyticsId
    appInsightsId: appInsightsId
    appInsightsConnectionString: appInsightsConnectionString
    modelGatewayApimSubnetId: modelGatewayApimSubnetId
    modelGatewayPeSubnetId: modelGatewayPeSubnetId
    hubVnetId: hubVnetId
  }
  dependsOn: [
    privateEndpoints
  ]
}

module project 'project.bicep' = {
  name: 'stage10-project-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    projectName: projectName
    projectDescription: projectDescription
    displayName: displayName
    accountName: foundryAccount.outputs.accountName
    aiSearchName: dataResources.outputs.aiSearchName
    aiSearchServiceResourceGroupName: dataResources.outputs.aiSearchServiceResourceGroupName
    aiSearchServiceSubscriptionId: dataResources.outputs.aiSearchServiceSubscriptionId
    cosmosDBName: dataResources.outputs.cosmosDBName
    cosmosDBSubscriptionId: dataResources.outputs.cosmosDBSubscriptionId
    cosmosDBResourceGroupName: dataResources.outputs.cosmosDBResourceGroupName
    azureStorageName: dataResources.outputs.azureStorageName
    azureStorageSubscriptionId: dataResources.outputs.azureStorageSubscriptionId
    azureStorageResourceGroupName: dataResources.outputs.azureStorageResourceGroupName
    logAnalyticsId: logAnalyticsId
  }
  dependsOn: [
    privateEndpoints
  ]
}

module rbac 'rbac.bicep' = {
  name: 'stage10-rbac-${uniqueSuffix}'
  params: {
    uniqueSuffix: uniqueSuffix
    projectCapHost: projectCapHost
    azureStorageName: dataResources.outputs.azureStorageName
    aiSearchName: dataResources.outputs.aiSearchName
    cosmosDBName: dataResources.outputs.cosmosDBName
    acrName: dataResources.outputs.acrName
    appInsightsName: appInsightsName
    accountName: foundryAccount.outputs.accountName
    accountPrincipalId: foundryAccount.outputs.accountPrincipalId
    projectName: project.outputs.projectName
    projectPrincipalId: project.outputs.projectPrincipalId
    projectWorkspaceIdGuid: project.outputs.projectWorkspaceIdGuid
    cosmosDBConnection: project.outputs.cosmosDBConnection
    azureStorageConnection: project.outputs.azureStorageConnection
    aiSearchConnection: project.outputs.aiSearchConnection
  }
  dependsOn: [
    privateEndpoints
  ]
}

module encryption 'encryption.bicep' = {
  name: 'stage10-encryption-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    keyVaultName: dataResources.outputs.keyVaultName
    keyVaultUri: dataResources.outputs.keyVaultUri
    keyName: dataResources.outputs.keyName
    keyUriWithVersion: dataResources.outputs.keyUriWithVersion
    accountName: foundryAccount.outputs.accountName
    accountPrincipalId: foundryAccount.outputs.accountPrincipalId
    azureStorageName: dataResources.outputs.azureStorageName
    storagePrincipalId: dataResources.outputs.storagePrincipalId
    aiSearchPrincipalId: dataResources.outputs.aiSearchPrincipalId
    projectPrincipalId: project.outputs.projectPrincipalId
    agentSubnetId: agentSubnetId
    restrictOutboundNetworkAccess: foundryRestrictOutboundNetworkAccess
    allowedFqdnList: foundryAllowedFqdnList
    storageSkuName: storageSkuName
  }
}

// ==================== OUTPUTS (consumed by still-in-main modules + stage 30/40) ====================

// Foundry account + Key Vault
output aiAccountName string = foundryAccount.outputs.accountName
output keyVaultName string = dataResources.outputs.keyVaultName

// Dependent resources (App Service)
output yarpWebAppFqdn string = dataResources.outputs.yarpWebAppFqdn

// Project
output projectName string = project.outputs.projectName
output projectId string = project.outputs.projectId
output projectEndpoint string = project.outputs.projectEndpoint

// Model gateway
output providerAccountId string = modelGateway.outputs.providerAccountId
output apimName string = modelGateway.outputs.apimName
output gatewayUrl string = modelGateway.outputs.gatewayUrl
