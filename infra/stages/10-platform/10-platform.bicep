/*
Stage 10 — Platform (orchestrator)

The data substrate + shared gateway on top of the stage 00 network/observability
foundation. Composes the slices —
  data-resources.bicep         → Key Vault (CMK holder), dependent resources
                                 (Storage/Cosmos/Search/App Service), container registry
  private-endpoints.bicep      → data-resource private endpoints + privatelink DNS
  model-gateway-platform.bicep → provider Foundry, APIM, APIM/provider PEs, APIM
                                 provider RBAC
  rbac/keyvault-storage-search-role-assignment.bicep → Storage/Search KV Crypto grants
  encryption/storage-encryption.bicep → Storage CMK re-PUT
  encryption/search-encryption.bicep  → AI Search service-level CMK re-PUT

The Foundry account lives in stage 13 (13-foundry) and the AI project in stage 15
(15-foundry-project), each carrying its own private endpoint, RBAC and CMK encryption.
This stage re-exposes the names/ids the account/project stages + stage 30/40 read.
*/

param location string
param uniqueSuffix string

// Dependent resource + naming.
param appServicePlanName string
param keyVaultName string
param azureStorageName string
param aiSearchName string
param cosmosDBName string
param acrName string
param appInsightsName string
param apimGatewayUrl string

@description('Optional provisioning-operator public IP to allow into the public YARP edge. Empty = Teams-only.')
param deployerPublicIp string = ''

// Storage SKU (computed in main; stage 00 needs it too; used by the storage CMK re-PUT).
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
param logAnalyticsId string
param appInsightsConnectionString string
param appInsightsId string
param appServiceDelegatedSubnetId string
param hubVnetId string
param foundrySpokeVnetName string
param foundryPeSubnetName string
param modelGatewayApimSubnetId string
param modelGatewayPeSubnetId string

// Private DNS zone ids for the data-resource PEs (created early in stage 00 foundation).
param aiSearchDnsZoneId string
param storageDnsZoneId string
param cosmosDBDnsZoneId string
param acrDnsZoneId string
param keyVaultDnsZoneId string

@description('Deploy the STANDARD agent tier (BYO Cosmos/Storage/Search + their private endpoints, CMK, KV-crypto RBAC). False = BASIC tier: none of the BYO data plane is deployed.')
param deployStandardAgent bool

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
    apimGatewayUrl: apimGatewayUrl
    deployerPublicIp: deployerPublicIp
    deployStandardAgent: deployStandardAgent
    logAnalyticsId: logAnalyticsId
    appServiceDelegatedSubnetId: appServiceDelegatedSubnetId
  }
}

module privateEndpoints 'private-endpoints.bicep' = {
  name: 'stage10-private-endpoints-${uniqueSuffix}'
  params: {
    uniqueSuffix: uniqueSuffix
    deployStandardAgent: deployStandardAgent
    aiSearchName: dataResources.outputs.aiSearchName
    storageName: dataResources.outputs.azureStorageName
    cosmosDBName: dataResources.outputs.cosmosDBName
    acrName: dataResources.outputs.acrName
    keyVaultName: dataResources.outputs.keyVaultName
    foundrySpokeVnetName: foundrySpokeVnetName
    foundryPeSubnetName: foundryPeSubnetName
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

// ==================== Data-store CMK (STANDARD tier only) ====================
// Grant the Storage + Search service identities the Key Vault Crypto Service Encryption
// User role, THEN re-PUT the Storage account and AI Search service with customer-managed-key
// encryption (the KV data-plane role must be effective first). The account CMK re-PUT lives in
// stage 13.
module keyVaultStorageSearchRoleAssignments 'rbac/keyvault-storage-search-role-assignment.bicep' = if (deployStandardAgent) {
  name: 'keyvault-storage-search-rbac-${uniqueSuffix}-deployment'
  params: {
    keyVaultName: dataResources.outputs.keyVaultName
    storagePrincipalId: dataResources.outputs.storagePrincipalId
    aiSearchPrincipalId: dataResources.outputs.aiSearchPrincipalId
  }
}

module storageEncryption 'encryption/storage-encryption.bicep' = if (deployStandardAgent) {
  name: 'storage-encryption-${uniqueSuffix}-deployment'
  params: {
    storageName: dataResources.outputs.azureStorageName
    location: location
    keyVaultUri: dataResources.outputs.keyVaultUri
    keyVaultKeyName: dataResources.outputs.keyName
    skuName: storageSkuName
  }
  dependsOn: [
    keyVaultStorageSearchRoleAssignments
  ]
}

// Set the AI Search service-level customer-managed key (re-PUT). The base service enables CMK
// enforcement but leaves the key unset; without a service-level key every new object would need
// its own object-level key. Runs after the KV Crypto role grant so the search identity can
// wrap/unwrap with the vault key.
module searchEncryption 'encryption/search-encryption.bicep' = if (deployStandardAgent) {
  name: 'search-encryption-${uniqueSuffix}-deployment'
  params: {
    aiSearchName: dataResources.outputs.aiSearchName
    location: location
    keyVaultUri: dataResources.outputs.keyVaultUri
    keyVaultKeyName: dataResources.outputs.keyName
    keyVaultKeyVersion: last(split(dataResources.outputs.keyUriWithVersion, '/'))
  }
  dependsOn: [
    keyVaultStorageSearchRoleAssignments
  ]
}

// ==================== OUTPUTS (consumed by stages 13/15/20/30/40 + still-in-main modules) ====================

// Key Vault (CMK) — consumed by the account (stage 13) + project (stage 15) CMK grants/re-PUTs.
output keyVaultName string = dataResources.outputs.keyVaultName
output keyVaultUri string = dataResources.outputs.keyVaultUri
output keyName string = dataResources.outputs.keyName
output keyUriWithVersion string = dataResources.outputs.keyUriWithVersion

// Dependent-resource identity/location — consumed by the project (stage 15).
output acrName string = dataResources.outputs.acrName
output azureStorageName string = dataResources.outputs.azureStorageName
output azureStorageSubscriptionId string = dataResources.outputs.azureStorageSubscriptionId
output azureStorageResourceGroupName string = dataResources.outputs.azureStorageResourceGroupName
output aiSearchName string = dataResources.outputs.aiSearchName
output aiSearchServiceResourceGroupName string = dataResources.outputs.aiSearchServiceResourceGroupName
output aiSearchServiceSubscriptionId string = dataResources.outputs.aiSearchServiceSubscriptionId
output cosmosDBName string = dataResources.outputs.cosmosDBName
output cosmosDBSubscriptionId string = dataResources.outputs.cosmosDBSubscriptionId
output cosmosDBResourceGroupName string = dataResources.outputs.cosmosDBResourceGroupName

// Dependent resources (App Service / YARP)
output yarpWebAppFqdn string = dataResources.outputs.yarpWebAppFqdn
output yarpWebAppName string = dataResources.outputs.yarpWebAppName

// Model gateway
output providerAccountId string = modelGateway.outputs.providerAccountId
output apimName string = modelGateway.outputs.apimName
output gatewayUrl string = modelGateway.outputs.gatewayUrl
