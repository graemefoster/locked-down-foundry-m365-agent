/*
Stage 10 slice — Data resources (Foundry dependent resources).
Key Vault (CMK holder), the standard dependent-resources bundle (Storage,
CosmosDB, AI Search + the App Service plan / YARP proxy / MCP web app) and the
container registry. Re-exposes every name/principal/connection id the encryption,
private-endpoint, project, rbac and gateway slices consume.
*/

param location string
param uniqueSuffix string

param keyVaultName string
param azureStorageName string
param aiSearchName string
param cosmosDBName string
param acrName string
param appServicePlanName string
param appInsightsName string
param enableTeamsPublish bool

// Foundry account name (wires the YARP proxy).
param foundryName string

// Deterministic gateway URL (threaded so no dependency on the APIM module).
param apimGatewayUrl string

// From stage 00.
param logAnalyticsId string
param appServiceDelegatedSubnetId string

module keyVault '../../modules/resources/keyvault.bicep' = {
  name: 'keyvault-${uniqueSuffix}-deployment'
  params: {
    keyVaultName: keyVaultName
    location: location
    logAnalyticsId: logAnalyticsId
  }
}

// Create agent dependent resources (Storage, CosmosDB, AI Search, App Service)
module aiDependencies '../../modules/resources/standard-dependent-resources.bicep' = {
  name: 'dependencies-${uniqueSuffix}-deployment'
  params: {
    location: location
    azureStorageName: azureStorageName
    aiSearchName: aiSearchName
    cosmosDBName: cosmosDBName

    logAnalyticsId: logAnalyticsId
    appServicePlanName: appServicePlanName

    appInsightsName: appInsightsName
    appServiceDelegationSubnetId: appServiceDelegatedSubnetId

    //wire up the YARP proxy
    foundryName: foundryName
    enableTeamsPublish: enableTeamsPublish
    apimGatewayUrl: apimGatewayUrl

  }
}

module acr '../../modules/resources/acr.bicep' = {
  name: 'acr-${uniqueSuffix}-deployment'
  params: {
    location: location
    acrName: acrName
    logAnalyticsWorkspaceId: logAnalyticsId
  }
}

// Key Vault (CMK)
output keyVaultName string = keyVault.outputs.keyVaultName
output keyVaultUri string = keyVault.outputs.keyVaultUri
output keyName string = keyVault.outputs.keyName
output keyUriWithVersion string = keyVault.outputs.keyUriWithVersion

// Container registry
output acrName string = acr.outputs.acrName

// Dependent resources
output azureStorageName string = aiDependencies.outputs.azureStorageName
output azureStorageSubscriptionId string = aiDependencies.outputs.azureStorageSubscriptionId
output azureStorageResourceGroupName string = aiDependencies.outputs.azureStorageResourceGroupName
output aiSearchName string = aiDependencies.outputs.aiSearchName
output aiSearchServiceResourceGroupName string = aiDependencies.outputs.aiSearchServiceResourceGroupName
output aiSearchServiceSubscriptionId string = aiDependencies.outputs.aiSearchServiceSubscriptionId
output cosmosDBName string = aiDependencies.outputs.cosmosDBName
output cosmosDBSubscriptionId string = aiDependencies.outputs.cosmosDBSubscriptionId
output cosmosDBResourceGroupName string = aiDependencies.outputs.cosmosDBResourceGroupName
output storagePrincipalId string = aiDependencies.outputs.storagePrincipalId
output aiSearchPrincipalId string = aiDependencies.outputs.aiSearchPrincipalId
output yarpWebAppName string = aiDependencies.outputs.yarpWebAppName
output yarpWebAppFqdn string = aiDependencies.outputs.yarpWebAppFqdn
