/*
Stage 10 slice — Data-resource private endpoints & DNS.
AI Search, Storage, CosmosDB, ACR and Key Vault all get private endpoints; the
privatelink DNS zones are linked to the hub VNet for the DNS resolver. The Foundry
account PE lives with the account in stage 13. The MCP web app PE lives in stage 20
(with the MCP workload); the YARP proxy is the public ingress, so it never gets a
private endpoint.
*/

param uniqueSuffix string

// Dependent-resource names (from the data-resources slice).
param aiSearchName string
param storageName string
param cosmosDBName string
param acrName string
param keyVaultName string

// From stage 00 networking.
param foundrySpokeVnetName string
param foundryPeSubnetName string

// Private DNS zone ids (created early in stage 00).
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
    aiSearchName: aiSearchName
    storageName: storageName
    cosmosDBName: cosmosDBName

    // Foundry Spoke (Foundry PEs go here)
    foundrySpokeVnetName: foundrySpokeVnetName
    foundryPeSubnetName: foundryPeSubnetName

    // Private DNS zone ids (created early in stage 00)
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
