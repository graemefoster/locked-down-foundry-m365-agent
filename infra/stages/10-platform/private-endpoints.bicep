/*
Stage 10 slice — Private endpoints & DNS.
Foundry account, AI Search, Storage, CosmosDB, ACR and Key Vault all get private
endpoints; the privatelink DNS zones are linked to the hub VNet for the DNS resolver.
The MCP web app PE lives in stage 20 (with the MCP workload); the YARP proxy is the
public ingress, so it never gets a private endpoint.
*/

param uniqueSuffix string

// Foundry account + dependent-resource names (from earlier slices).
param aiAccountName string
param aiSearchName string
param storageName string
param cosmosDBName string
param acrName string
param keyVaultName string

// From stage 00 networking.
param foundrySpokeVnetName string
param foundryPeSubnetName string

// Private DNS zone ids (created early in stage 00).
param aiServicesDnsZoneId string
param openAiDnsZoneId string
param cognitiveServicesDnsZoneId string
param aiSearchDnsZoneId string
param storageDnsZoneId string
param cosmosDBDnsZoneId string
param acrDnsZoneId string
param keyVaultDnsZoneId string

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

module privateEndpointAndDNS './network/private-endpoint-and-dns.bicep' = {
  name: '${uniqueSuffix}-private-endpoint'
  params: {
    aiAccountName: aiAccountName
    aiSearchName: aiSearchName
    storageName: storageName
    cosmosDBName: cosmosDBName

    // Foundry Spoke (Foundry PEs go here)
    foundrySpokeVnetName: foundrySpokeVnetName
    foundryPeSubnetName: foundryPeSubnetName

    // Private DNS zone ids (created early in stage 00)
    aiServicesDnsZoneId: aiServicesDnsZoneId
    openAiDnsZoneId: openAiDnsZoneId
    cognitiveServicesDnsZoneId: cognitiveServicesDnsZoneId
    aiSearchDnsZoneId: aiSearchDnsZoneId
    storageDnsZoneId: storageDnsZoneId
    cosmosDBDnsZoneId: cosmosDBDnsZoneId
    acrDnsZoneId: acrDnsZoneId
    keyVaultDnsZoneId: keyVaultDnsZoneId

    acrName: acrName
    keyVaultName: keyVaultName
  }
  dependsOn: [
    aiSearch
    storage
    cosmosDB
  ]
}
