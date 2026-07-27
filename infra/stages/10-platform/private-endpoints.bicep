/*
Stage 10 slice — Private endpoints & DNS.
Foundry account, AI Search, Storage, CosmosDB, ACR, Key Vault and the App Service
web app(s) all get private endpoints; the privatelink DNS zones are linked to the
hub VNet for the DNS resolver. When Teams publish is on the YARP proxy is public
(no PE) — only the MCP web app gets one.
*/

param uniqueSuffix string
param enableTeamsPublish bool

// Foundry account + dependent-resource names (from earlier slices).
param aiAccountName string
param aiSearchName string
param storageName string
param cosmosDBName string
param acrName string
param keyVaultName string
param mcpWebAppName string
param yarpWebAppName string

// From stage 00 networking.
param hubVnetName string
param foundrySpokeVnetName string
param foundryPeSubnetName string
param appServiceSpokeVnetName string
param appServicePeSubnetName string

// Existing data-plane resources (declared for the dependsOn ordering preserved from main).
resource storage 'Microsoft.Storage/storageAccounts@2022-05-01' existing = {
  name: storageName
}

resource aiSearch 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: aiSearchName
}

resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosDBName
}

module privateEndpointAndDNS '../../modules/network/private-endpoint-and-dns.bicep' = {
  name: '${uniqueSuffix}-private-endpoint'
  params: {
    aiAccountName: aiAccountName
    aiSearchName: aiSearchName
    storageName: storageName
    cosmosDBName: cosmosDBName

    // Hub VNet (DNS zones linked here for resolver)
    hubVnetName: hubVnetName

    // Foundry Spoke (Foundry PEs go here)
    foundrySpokeVnetName: foundrySpokeVnetName
    foundryPeSubnetName: foundryPeSubnetName

    // App Service Spoke (App Service PEs go here)
    appServiceSpokeVnetName: appServiceSpokeVnetName
    appServicePeSubnetName: appServicePeSubnetName

    suffix: uniqueSuffix
    // When Teams publish is enabled the YARP proxy is public (its own FQDN + managed cert is
    // the Bot Channel Adapter entry point), so it gets NO private endpoint — only the MCP web
    // app does. Otherwise both get private endpoints (legacy private-only posture).
    appServiceWebAppNames: enableTeamsPublish
      ? [mcpWebAppName]
      : [yarpWebAppName, mcpWebAppName]
    acrName: acrName
    keyVaultName: keyVaultName
  }
  dependsOn: [
    aiSearch
    storage
    cosmosDB
  ]
}
