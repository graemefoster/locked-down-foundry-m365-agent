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

// Deterministic gateway URL (threaded so no dependency on the APIM module).
param apimGatewayUrl string

@description('Optional provisioning-operator public IP to allow into the public YARP edge (dev/test). Empty = Teams-only.')
param deployerPublicIp string = ''

// From stage 00.
param logAnalyticsId string
param appServiceDelegatedSubnetId string

module keyVault './resources/keyvault.bicep' = {
  name: 'keyvault-${uniqueSuffix}-deployment'
  params: {
    keyVaultName: keyVaultName
    location: location
    logAnalyticsId: logAnalyticsId
  }
}

// Create agent dependent resources. YARP proxy (App Service) is ALWAYS deployed. The BYO
// agent-state stores (Storage, CosmosDB, AI Search) are the STANDARD tier only — gated by
// deployStandardAgent; the BASIC tier runs on Microsoft-managed stores (account capability host).
@description('Deploy the Azure Firewall egress tier. When false, the BYO data plane + YARP edge additionally allow public network access (private endpoints retained).')
param deployFirewall bool

@description('Deploy the STANDARD agent tier (BYO Cosmos/Storage/Search). False = BASIC tier (no BYO stores).')
param deployStandardAgent bool

module aiDependencies './resources/standard-dependent-resources.bicep' = if (deployStandardAgent) {
  name: 'dependencies-${uniqueSuffix}-deployment'
  params: {
    location: location
    azureStorageName: azureStorageName
    aiSearchName: aiSearchName
    cosmosDBName: cosmosDBName

    logAnalyticsId: logAnalyticsId
    deployFirewall: deployFirewall
  }
}

// YARP reverse proxy (public Teams/M365 ingress) — always deployed, independent of the agent tier.
module appService './gateway/app-service.bicep' = {
  name: 'appServiceDeployment'
  params: {
    location: location
    logAnalyticsId: logAnalyticsId
    aspName: appServicePlanName
    appInsightsName: appInsightsName
    appServiceDelegationSubnetId: appServiceDelegatedSubnetId

    //wire up the YARP proxy
    apimGatewayUrl: apimGatewayUrl
    deployerPublicIp: deployerPublicIp
    deployFirewall: deployFirewall
  }
}

module acr './resources/acr.bicep' = {
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

// BYO agent-state stores — empty in the BASIC tier (not deployed).
output azureStorageName string = deployStandardAgent ? aiDependencies!.outputs.azureStorageName : ''
output azureStorageSubscriptionId string = deployStandardAgent ? aiDependencies!.outputs.azureStorageSubscriptionId : ''
output azureStorageResourceGroupName string = deployStandardAgent ? aiDependencies!.outputs.azureStorageResourceGroupName : ''
output aiSearchName string = deployStandardAgent ? aiDependencies!.outputs.aiSearchName : ''
output aiSearchServiceResourceGroupName string = deployStandardAgent ? aiDependencies!.outputs.aiSearchServiceResourceGroupName : ''
output aiSearchServiceSubscriptionId string = deployStandardAgent ? aiDependencies!.outputs.aiSearchServiceSubscriptionId : ''
output cosmosDBName string = deployStandardAgent ? aiDependencies!.outputs.cosmosDBName : ''
output cosmosDBSubscriptionId string = deployStandardAgent ? aiDependencies!.outputs.cosmosDBSubscriptionId : ''
output cosmosDBResourceGroupName string = deployStandardAgent ? aiDependencies!.outputs.cosmosDBResourceGroupName : ''
output storagePrincipalId string = deployStandardAgent ? aiDependencies!.outputs.storagePrincipalId : ''
output aiSearchPrincipalId string = deployStandardAgent ? aiDependencies!.outputs.aiSearchPrincipalId : ''

// YARP (always deployed)
output yarpWebAppName string = appService.outputs.yarpWebAppName
output yarpWebAppFqdn string = appService.outputs.yarpWebAppFqdn
